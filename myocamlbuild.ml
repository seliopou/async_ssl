(* OASIS_START *)
(* OASIS_STOP *)

module JS = Jane_street_ocamlbuild_goodies

let dev_mode = true

let setup_preprocessor_deps = function
  | After_rules ->
    dep ["pp_deps_for_bindings"] ["bindings/config.h"];
  | _ -> ()

let split str =
  let rec skip_spaces i =
    if i = String.length str then
      []
    else
      if str.[i] = ' ' then
        skip_spaces (i + 1)
      else
        extract i (i + 1)
  and extract i j =
    if j = String.length str then
      [String.sub str i (j - i)]
    else
      if str.[j] = ' ' then
        String.sub str i (j - i) :: skip_spaces (j + 1)
      else
        extract i (j + 1)
  in
  skip_spaces 0

let get_flags var env =
  try
    List.map (fun x -> A x) (split (BaseEnvLight.var_get var env))
  with Not_found ->
    Printf.ksprintf failwith "Variable %s not defined in setup.data" var

let dispatch = function
  | After_rules ->
    let env = BaseEnvLight.load () in

    let ccopt = get_flags "openssl_ccopt" env
    and cclib = get_flags "openssl_cclib" env in

    let stubgen          = "stubgen/ffi_stubgen.byte" in
    let stubgen_types    = "stubgen/ffi_types_stubgen.byte" in
    let stubgen_ml_types = "stubgen/ffi_ml_types_subgen.exe" in

    rule "generated ml"
      ~dep:stubgen
      ~prod:"src/ffi_generated.ml"
      (fun _ _ ->
         Cmd(S[P stubgen; A"-ml"; Sh">"; A"src/ffi_generated.ml"]));

    rule "generated-types c"
      ~dep:stubgen_types
      ~prod:"stubgen/ffi_ml_types_stubgen.c"
      (fun _ _ ->
         Cmd (S [P stubgen_types; Sh">"; A"stubgen/ffi_ml_types_stubgen.c"]));

    let cc = BaseEnvLight.var_get "bytecomp_c_compiler" env in

    (let stdlib : string = BaseEnvLight.var_get "standard_library" env in
     let ctypes = BaseEnvLight.var_get "pkg_ctypes" env in
     rule "generated-types exe"
       ~dep:"stubgen/ffi_ml_types_stubgen.c"
       ~prod:stubgen_ml_types
       (fun _ _ ->
          Cmd (S [Sh cc; A"stubgen/ffi_ml_types_stubgen.c";
                  A"-I"; P ctypes; A"-I"; P stdlib;
                  S ccopt;
                  A"-o"; A stubgen_ml_types])
       ));

    let discover_c   = "bindings/discover.c"   in
    let discover_exe = "bindings/discover.exe" in
    let config_h     = "bindings/config.h"     in

    rule "discover tool"
      ~dep:discover_c
      ~prod:discover_exe
      (fun _ _ ->
        match run_and_read "uname" |> String.trim with
        | "FreeBSD" ->
         Cmd (S [Sh cc; A discover_c; S ccopt; S cclib; A"-o"; A discover_exe])
        | _ ->
         Cmd (S [Sh cc; A discover_c; S ccopt; S cclib; A"-ldl"; A"-o"; A discover_exe]));

    rule "config.h file"
      ~dep:discover_exe
      ~prod:config_h
      (fun _ _ ->
         Cmd (S [P discover_exe; Sh">"; A config_h]));

    rule "generated-types ml"
      ~dep:stubgen_ml_types
      ~prod:"src/ffi_generated_types.ml"
      (fun _ _ ->
         Cmd (S [P stubgen_ml_types; Sh">>"; A"src/ffi_generated_types.ml"]));

    rule "generated c"
      ~dep:stubgen
      ~prod:"src/ffi_generated_stubs.c"
      (fun _ _ ->
         Cmd(S[P stubgen; A"-c"; Sh">"; A"src/ffi_generated_stubs.c"]));

    flag ["c"; "compile"] & S[A"-I"; A"src"; A"-package"; A"ctypes"];

    let tag_ccopt = "use_openssl_ccopt"
    and tag_cclib = "use_openssl_cclib" in

    (* Add flags for linking with the C library: *)
    flag ["ocamlmklib"; "c"; tag_cclib] & S cclib;

    (* C stubs using the C library must be compiled with the library
       specifics flags: *)
    flag ["c"; "compile"; tag_ccopt] & S (List.map (fun arg -> S[A"-ccopt"; arg]) ccopt);

    (* OCaml libraries must depends on the C library: *)
    flag ["link"; "ocaml"; tag_cclib] & S (List.map (fun arg -> S[A"-cclib"; arg]) cclib)

  | _ ->
    ()

let () =
  Ocamlbuild_plugin.dispatch (fun hook ->
    JS.alt_cmxs_of_cmxa_rule hook;
    JS.pass_predicates_to_ocamldep hook;
    if dev_mode && not Sys.win32 then JS.track_external_deps hook;
    setup_preprocessor_deps hook;
    Ppx_driver_ocamlbuild.dispatch hook;
    dispatch hook;
    dispatch_default hook)
