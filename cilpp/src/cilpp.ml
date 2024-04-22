(* cilpp -- a simple CIL driver that replaces the C preprocessor.
 *
 * Copyright 2018--19   Stephen Kell <stephen.kell@cl.cam.ac.uk>
 *   and embodying parts of CIL's main.ml, which is
 * Copyright (c) 2001-2002, 
 *  George C. Necula    <necula@cs.berkeley.edu>
 *  Scott McPeak        <smcpeak@cs.berkeley.edu>
 *  Wes Weimer          <weimer@cs.berkeley.edu>
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 * IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *)
 
(* First we preprocess into a temporary file;
 * we pass through to cpp all our arguments except for any following "-o".
 * Then we run CIL and output to the intended -o file.
 *
 * FIXME: we have an identity crisis. Do we emulate 'cpp' or 'cc -E'?
 * Although the former sounds right, we are already forced to use the latter
 * in some cases, because we may not know which 'cpp' command to run, but
 * we can usually figure out the driver (albeit from parent-PID hackery
 * or from an explicit -driver option).
 * Even GNU 'make' defaults CPP to 'cc -E'.
 *
 * This matters because '-MD' has different semantics between 'cpp' and
 * 'cc -E' (separately from how it has even more-different semantics in 'cc1').
 * HMM, or does it?
 *
 * The most appealing situation is where we emulate only a common subset
 * of 'cc -E' and 'cpp'. Using 'wrapper' we could arrange this. The idea is
 * to centralise understanding of command-line options in 'wrapper', not in
 * this tool. For example, we could require that '-o', '-E' and '-fpass-*'
 * appear before other options. Without this kind of assumption, we have to
 * understand the whole command line e.g. to avoid getting confused by
 * perversities like "-MF -o" where an earlier option's argument looks like
 * an option. There are already cases like "-D _FORTIFY_SOURCE"
 *)
open Compiler_args
open Unix
open Feature

type cilpp_extra_arg = [
    basic_extra_arg
  | `ArgNamingPlugin
  | `ArgNamingRealCPP
  ]

let runCppDivertingToTempFile maybeSuffix argChunks basicInfo =
    let saveTemps = ref false in
    let ppPluginsToLoadReverse = ref [] in
    let ppPassesToRunReverse = ref [] in
    let realCpp = ref None in
    let readingExtraArg = ref None in
    (* chunkedArgs is a list with exactly the same number of entries
     * as the original arg list, but where adjacent options belong together,
     * the earlier ones appear as [] and the completed chunk appears as [arg1; arg2] or whatever.
     * As we go, we snarf various properties that interest us, and we
     * gobble (replace with []) any arg that is private to us, i.e. that the real cpp doesn't grok.
     * This is really the only crucial argument processing that we need to do here:
     * pull out "-save-temps", "-plugin" and "-fpass-*". *)
    let reChunkedArgs = List.mapi (fun i -> fun argChunk ->
        match argChunk with
          | ["-save-temps"] -> saveTemps := true; [] (* i.e. accept -Wp,-save-temps; compiler doesn't grok it*)
          | ["-realcpp"] -> (readingExtraArg := Some(`ArgNamingRealCPP); [])
          | ["-plugin"] -> (readingExtraArg := Some(`ArgNamingPlugin); [])
          | [s] when None <> matchesPrefix "-fpass-" s ->
                let passName = really (matchesPrefix "-fpass-" s) in
                ppPassesToRunReverse := passName :: !ppPassesToRunReverse; []
          | [] -> []
          | [arg] -> (
            let wasReadingExtraArg = !readingExtraArg in
            readingExtraArg := None;
            match wasReadingExtraArg with
                None -> argChunk (* i.e. no-op *)
              | Some(`ArgNamingPlugin) -> ppPluginsToLoadReverse := arg :: !ppPluginsToLoadReverse; []
              | Some(`ArgNamingRealCPP) -> realCpp := Some(arg); []
           )
          | _ -> ( (* This case matches non-singleton lists i.e. already-formed chunks *)
            let wasReadingExtraArg = !readingExtraArg in
                readingExtraArg := None;
                if None <> wasReadingExtraArg then
                (* This means we are trying to form a chunk, given the preceding argument,
                 * but instead we saw something already chunked-up. Flag an error. *)
                failwith ""
                else argChunk
            )
    ) argChunks
    in
    (* What we don't do is identify which arguments denote input files.
     * We'd like to guess the right suffix for a temporary file, but this
     * is challenging. Luckily we insist on either -driver or -std=, and
     * these are enough -- but don't forget -x lang if we saw it. FIXME:
     * testing for driver names is really gross. Can we really not find
     * the input filename? Or at least make a guess and use it instead
     * of hardcoded "c" below? *)
    let cppCommandPrefix, guessedLang = guessCppCommandAndLang basicInfo !realCpp in
    let suffixOfLang l = match l with
        "c++" -> "ii"
      | "c" -> "i" (* FIXME: other languages are possible *)
      | _ -> failwith (l ^ " is not a language")
    in
    let (newTempFd, newTempName) =
        let suffix = if maybeSuffix <> None then really maybeSuffix else suffixOfLang guessedLang
        in mkstemps ("/tmp/tmp.XXXXXX.cpp." ^ suffix) (String.length ".cpp." + String.length suffix)
    in
    let rewrittenArgs = List.flatten (List.mapi (fun i -> fun argChunk ->
        if i = 0 then [] (* we fill "cpp" or whatever from cppCommandPrefix *) else
        match argChunk with
          | ["-o"; filename] ->  ["-o"; newTempName]
          | _ -> argChunk) reChunkedArgs)
      @ ( (* we might not have seen "-o" -- ensure there is a -o argument *)
      match basicInfo.minus_o_pos with
        None -> (* there was no -o, so add one *) [ "-o"; newTempName ]
      | _ -> [])
    in
    runCommand (* 'cpp' here is used only in error messages... *) "cpp" (cppCommandPrefix @ rewrittenArgs);
    (newTempName, basicInfo.output_file, !saveTemps, List.rev !ppPluginsToLoadReverse, List.rev !ppPassesToRunReverse)

let () =
    let argList = Array.to_list Sys.argv in
    let (argChunks, basicInfo) = scanAndChunkCppArgs argList in
    if basicInfo.suppress_ppout then
        (* the command doesn't generate any preprocessed output, so we have nothing
         * to do... just run the original command. This should arguably get filtered
         * out in the wrapper scripts, so that cilpp does not have to handle it,
         * i.e. an extension of just handling vanilla "cc -E" or "cpp" invocations. *)
         runCommand "cpp" (* <-- only used in error messages *) argList
    else
    let (newTempName, originalOutfile, saveTemps, ppPluginsToLoad, ppPassesToRun)
     = runCppDivertingToTempFile (Some "i") argChunks basicInfo in
    (* Okay, run CIL; we need the post-preprocessing line directive style *)
    Cil.lineDirectiveStyle := Some Cil.LinePreprocessorOutput;
    (* We have to use logical operators to avoid breaking code that does -Werror=format-string
     * ... this involves an expression-level check of the first argument to printf, which
     * might be a conditional expression. So we can't substitute it with a temporary assigned
     * in an if/else construct. *)
    Cil.useLogicalOperators := true;
    let initialCilFile = Frontc.parse newTempName () in
    (* do passes *)
    List.iter Feature.loadWithDeps ppPluginsToLoad;
    let features = ppPassesToRun in
    List.iter Feature.enable features;
    (* Errormsg.verboseFlag := true; *)
    let currentCilFile = initialCilFile in
    (* HACKED based on CIL's main.ml:
     * Scan all the registered features and, if they are 
     * enabled then run them on the current file *)
    List.iter
      (fun fdesc -> 
        if fdesc.Feature.fd_enabled then begin
          if !Errormsg.verboseFlag then 
            ignore (Errormsg.log "Running CIL feature %s (%s)\n" 
                      fdesc.Feature.fd_name fdesc.Feature.fd_description);
          try
          (* Run the feature, and see how long it takes. *)
          Stats.time fdesc.Feature.fd_name
            fdesc.Feature.fd_doit currentCilFile
          with Not_found -> (output_string Pervasives.stderr ("CIL pass " ^ fdesc.Feature.fd_name ^ " raised Not_found!\n"); raise Not_found);
          (* See if we need to do some checking *)
          if !Cilutil.doCheck && fdesc.Feature.fd_post_check then begin
            ignore (Errormsg.log "CIL check after %s\n" fdesc.Feature.fd_name);
            if not (Check.checkFile [] currentCilFile) && !Cilutil.strictChecking then begin
              Errormsg.error ("Feature \"%s\" left CIL's internal data "
                       ^^"structures in an inconsistent state. "
                       ^^"(See the warnings above)") fdesc.Feature.fd_name
            end
          end
        end)
      (Feature.list_registered ());
    Cil.printerForMaincil := Cil.defaultCilPrinter;
    (* We are not printing for CIL input *)
    Cil.print_CIL_Input := false;
    let (chan, str) = match originalOutfile with
            None -> Pervasives.stdout, "(stdout)"
          | Some(fname) -> (Pervasives.open_out fname, fname)
    in
    let _ = Cil.dumpFile Cil.defaultCilPrinter chan str currentCilFile
    in
    let status = if !Errormsg.hadErrors then 1 else 0 in
    (* delete temporary file unless -save-temps *)
    (if saveTemps then () else Unix.unlink newTempName;
    exit status)
