open Printf
open Scanf

let digit x =
  match x with
  | '0' .. '9' -> int_of_char x - int_of_char '0'
  | _ -> failwith "unexpected char: not digit"

let id_counter = ref 0

let make_id base =
  id_counter := !id_counter + 1 ;
  sprintf "%s.%d" base !id_counter

let program = read_line ()

type token =
  | IntLiteral of int
  | Plus
  | Minus
  | Star
  | Slash
  | Ident of string
  | LParen
  | RParen
  | Let
  | Equal
  | In
  | Rec

exception EOF

let rec tokenize i =
  let next_char i =
    if i < String.length program then (i + 1, program.[i]) else raise EOF
  in
  let rec next_int i acc =
    try
      let i, ch = next_char i in
      match ch with
      | '0' .. '9' -> next_int i ((acc * 10) + digit ch)
      | _ -> (i - 1, acc)
    with EOF -> (i, acc)
  in
  let next_ident i =
    let buf = Buffer.create 5 in
    let rec aux i =
      try
        let i, ch = next_char i in
        match ch with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '\'' ->
          Buffer.add_char buf ch ; aux i
        | _ -> (i - 1, Buffer.contents buf)
      with EOF -> (i, Buffer.contents buf)
    in
    aux i
  in
  try
    let i, ch = next_char i in
    match ch with
    | ' ' | '\t' | '\n' -> tokenize i
    | '0' .. '9' ->
      let i, num = next_int (i - 1) 0 in
      IntLiteral num :: tokenize i
    | 'a' .. 'z' | 'A' .. 'Z' ->
      let i, str = next_ident (i - 1) in
      ( match str with
        | "let" -> Let
        | "in" -> In
        | "rec" -> Rec
        | _ -> Ident str )
      :: tokenize i
    | '+' -> Plus :: tokenize i
    | '-' -> Minus :: tokenize i
    | '*' -> Star :: tokenize i
    | '/' -> Slash :: tokenize i
    | '(' -> LParen :: tokenize i
    | ')' -> RParen :: tokenize i
    | '=' -> Equal :: tokenize i
    | _ -> failwith (sprintf "unexpected char: '%c'" ch)
  with EOF -> []

type ast =
  | Int of int
  | Add of (ast * ast)
  | Sub of (ast * ast)
  | Mul of (ast * ast)
  | Div of (ast * ast)
  | Var of string
  | FuncCall of (ast * ast list)
  | LetVar of (string * ast * ast)
  | LetFunc of (string * string list * ast * ast)

let parse tokens =
  let rec parse_primary = function
    | IntLiteral num :: tokens -> (tokens, Int num)
    | Ident id :: tokens -> (tokens, Var id)
    | LParen :: tokens -> (
        let tokens, ast = parse_expression tokens in
        match tokens with
        | RParen :: tokens -> (tokens, ast)
        | _ -> failwith "unexpected token" )
    | _ -> failwith "unexpected token"
  and parse_funccall tokens =
    let rec aux tokens =
      match tokens with
      | (IntLiteral _ | Ident _ | LParen) :: _ ->
        (* if primary *)
        let tokens, arg = parse_primary tokens in
        let tokens, args = aux tokens in
        (tokens, arg :: args)
      | _ -> (tokens, [])
    in
    let tokens, func = parse_primary tokens in
    let tokens, args = aux tokens in
    if args = [] then (tokens, func) (* not function call *)
    else (tokens, FuncCall (func, args))
  and parse_multiplicative tokens =
    let rec aux lhs tokens =
      match tokens with
      | Star :: tokens ->
        let tokens, rhs = parse_funccall tokens in
        aux (Mul (lhs, rhs)) tokens
      | Slash :: tokens ->
        let tokens, rhs = parse_funccall tokens in
        aux (Div (lhs, rhs)) tokens
      | _ -> (tokens, lhs)
    in
    let tokens, ast = parse_funccall tokens in
    aux ast tokens
  and parse_additive tokens =
    let rec aux lhs tokens =
      match tokens with
      | Plus :: tokens ->
        let tokens, rhs = parse_multiplicative tokens in
        aux (Add (lhs, rhs)) tokens
      | Minus :: tokens ->
        let tokens, rhs = parse_multiplicative tokens in
        aux (Sub (lhs, rhs)) tokens
      | _ -> (tokens, lhs)
    in
    let tokens, ast = parse_multiplicative tokens in
    aux ast tokens
  and parse_let tokens =
    match tokens with
    | Let :: Ident varname :: Equal :: tokens -> (
        let tokens, lhs = parse_expression tokens in
        match tokens with
        | In :: tokens ->
          let tokens, rhs = parse_expression tokens in
          (tokens, LetVar (varname, lhs, rhs))
        | _ -> failwith "unexpected token" )
    | Let :: Ident funcname :: tokens -> (
        let rec aux = function
          | Ident argname :: tokens ->
            let tokens, args = aux tokens in
            (tokens, argname :: args)
          | Equal :: tokens -> (tokens, [])
          | _ -> failwith "unexpected token"
        in
        let tokens, args = aux tokens in
        let tokens, func = parse_expression tokens in
        match tokens with
        | In :: tokens ->
          let tokens, body = parse_expression tokens in
          (tokens, LetFunc (funcname, args, func, body))
        | _ -> failwith "unexpected token" )
    | _ -> parse_additive tokens
  and parse_expression tokens = parse_let tokens in
  let tokens, ast = parse_expression tokens in
  if tokens = [] then ast else failwith "invalid token sequence"

module HashMap = Map.Make (String)

type environment = {symbols: ast HashMap.t}

let analyze ast =
  let letfuncs = ref [] in
  let rec aux env ast =
    match ast with
    | Int _ -> ast
    | Add (lhs, rhs) -> Add (aux env lhs, aux env rhs)
    | Sub (lhs, rhs) -> Sub (aux env lhs, aux env rhs)
    | Mul (lhs, rhs) -> Mul (aux env lhs, aux env rhs)
    | Div (lhs, rhs) -> Div (aux env lhs, aux env rhs)
    | Var name -> (
        try HashMap.find name env.symbols with Not_found ->
          failwith (sprintf "not found in analysis: %s" name) )
    | FuncCall (func, args) -> FuncCall (aux env func, List.map (aux env) args)
    | LetVar (varname, lhs, rhs) ->
      let env' = {symbols= HashMap.add varname (Var varname) env.symbols} in
      LetVar (varname, aux env lhs, aux env' rhs)
    | LetFunc (funcname, args, func, body) ->
      (* TODO: allow recursion *)
      let gen_funcname = make_id funcname in
      let env' =
        { symbols=
            List.fold_left
              (fun symbols arg -> HashMap.add arg (Var arg) symbols)
              env.symbols args }
      in
      let func = aux env' func in
      let env' =
        {symbols= HashMap.add funcname (Var gen_funcname) env.symbols}
      in
      let ast = LetFunc (gen_funcname, args, func, aux env' body) in
      letfuncs := ast :: !letfuncs ;
      ast
  in
  let symbols = HashMap.empty in
  let ast = aux {symbols} ast in
  let ast = LetFunc ("aqaml_main", ["aqaml_main_dummy"], ast, Int 0) in
  letfuncs := ast :: !letfuncs ;
  !letfuncs

type gen_environment = {offset: int; varoffset: int HashMap.t}

let rec generate letfuncs =
  let tag_int reg = sprintf "sal %s, 1\nor %s, 1" reg reg in
  let untag_int reg = sprintf "sar %s, 1" reg in
  let stack_size = ref 0 in
  let rec aux env ast =
    match ast with
    | Int num -> sprintf "mov rax, %d\n%s\npush rax" num (tag_int "rax")
    | Add (lhs, rhs) ->
      String.concat "\n"
        [ aux env lhs
        ; aux env rhs
        ; "pop rdi"
        ; untag_int "rdi"
        ; "pop rax"
        ; untag_int "rax"
        ; "add rax, rdi"
        ; tag_int "rax"
        ; "push rax" ]
    | Sub (lhs, rhs) ->
      String.concat "\n"
        [ aux env lhs
        ; aux env rhs
        ; "pop rdi"
        ; untag_int "rdi"
        ; "pop rax"
        ; untag_int "rax"
        ; "sub rax, rdi"
        ; tag_int "rax"
        ; "push rax" ]
    | Mul (lhs, rhs) ->
      String.concat "\n"
        [ aux env lhs
        ; aux env rhs
        ; "pop rdi"
        ; untag_int "rdi"
        ; "pop rax"
        ; untag_int "rax"
        ; "imul rax, rdi"
        ; tag_int "rax"
        ; "push rax" ]
    | Div (lhs, rhs) ->
      String.concat "\n"
        [ aux env lhs
        ; aux env rhs
        ; "pop rdi"
        ; untag_int "rdi"
        ; "pop rax"
        ; untag_int "rax"
        ; "cqo"
        ; "idiv rdi"
        ; tag_int "rax"
        ; "push rax" ]
    | Var varname -> (
        try
          let offset = HashMap.find varname env.varoffset in
          String.concat "\n" [sprintf "mov rax, [rbp + %d]" offset; "push rax"]
        with Not_found -> failwith (sprintf "not found in analysis: %s" varname)
      )
    | FuncCall (func, args) ->
      String.concat "\n"
        [ aux env func
        ; String.concat "\n" (List.map (aux env) args)
        ; String.concat "\n"
            (List.map
               (fun (_, reg) -> "pop " ^ reg)
               (List.filter
                  (fun (index, reg) -> index < List.length args)
                  [ (0, "rax")
                  ; (1, "rbx")
                  ; (2, "rdi")
                  ; (3, "rsi")
                  ; (4, "rdx")
                  ; (5, "rcx")
                  ; (6, "r8")
                  ; (7, "r9")
                  ; (8, "r12")
                  ; (9, "r13") ]))
        ; "pop r10"
        ; "call r10"
        ; "push rax" ]
    | LetVar (varname, lhs, rhs) ->
      let lhs_code = aux env lhs in
      let offset = env.offset - 8 in
      stack_size := max !stack_size (-offset) ;
      let env =
        {offset; varoffset= HashMap.add varname offset env.varoffset}
      in
      String.concat "\n"
        [ lhs_code
        ; "pop rax"
        ; sprintf "mov [rbp + %d], rax" offset
        ; aux env rhs ]
    | LetFunc (funcname, _, _, body) ->
      let offset = env.offset - 8 in
      stack_size := max !stack_size (-offset) ;
      let env =
        {offset; varoffset= HashMap.add funcname offset env.varoffset}
      in
      String.concat "\n"
        [ sprintf "lea rax, [rip + %s]" funcname
        ; sprintf "mov [rbp + %d], rax" offset
        ; aux env body ]
        (* | _ -> failwith "unexpected ast" *)
  in
  let letfuncs_code =
    String.concat "\n"
      (List.map
         (function
           | LetFunc (funcname, args, func, _) ->
             let env = {offset= 0; varoffset= HashMap.empty} in
             let env =
               List.fold_left
                 (fun env argname ->
                    let offset = env.offset - 8 in
                    let varoffset =
                      HashMap.add argname offset env.varoffset
                    in
                    {offset; varoffset} )
                 env args
             in
             stack_size := -env.offset ;
             let code = aux env func in
             String.concat "\n"
               [ funcname ^ ":"
               ; "push rbp"
               ; "mov rbp, rsp"
               ; sprintf "sub rsp, %d" !stack_size
               ; String.concat "\n"
                   (List.map
                      (fun (i, reg) ->
                         sprintf "mov [rbp - %d], %s" ((i + 1) * 8) reg )
                      (List.filter
                         (fun (index, reg) -> index < List.length args)
                         [ (0, "rax")
                         ; (1, "rbx")
                         ; (2, "rdi")
                         ; (3, "rsi")
                         ; (4, "rdx")
                         ; (5, "rcx")
                         ; (6, "r8")
                         ; (7, "r9")
                         ; (8, "r12")
                         ; (9, "r13") ]))
               ; code
               ; "pop rax"
               ; "mov rsp, rbp"
               ; "pop rbp"
               ; "ret\n" ]
           | _ -> failwith "LetFunc should be here")
         letfuncs)
  in
  let main_code =
    String.concat "\n" ["main:"; "call aqaml_main"; "sar rax, 1"; "ret\n\n"]
  in
  main_code ^ letfuncs_code

;;
let ast = parse (tokenize 0) in
let code = generate (analyze ast) in
print_string
  (String.concat "\n" [".intel_syntax noprefix"; ".global main"; code])
