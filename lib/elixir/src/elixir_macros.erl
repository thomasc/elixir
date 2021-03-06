%% Those macros behave like they belong to Kernel,
%% but do not since they need to be implemented in Erlang.
-module(elixir_macros).
-export([translate_macro/2]).
-import(elixir_translator, [translate_each/2, translate/2, translate_args/2, translate_apply/7]).
-import(elixir_scope, [umergec/2]).
-import(elixir_errors, [syntax_error/3, syntax_error/4,
  assert_no_function_scope/3, assert_module_scope/3, assert_no_assign_or_guard_scope/3]).
-include("elixir.hrl").

-define(FUNS(), Kind == def; Kind == defp; Kind == defmacro; Kind == defmacrop).
-compile({parse_transform, elixir_transform}).

%% Operators

translate_macro({ '+', _Line, [Expr] }, S) when is_number(Expr) ->
  translate_each(Expr, S);

translate_macro({ '-', _Line, [Expr] }, S) when is_number(Expr) ->
  translate_each(-1 * Expr, S);

translate_macro({ Op, Line, Exprs }, S) when is_list(Exprs),
    Op == '<-' orelse Op == '--' ->
  assert_no_assign_or_guard_scope(Line, Op, S),
  translate_each({ '__op__', Line, [Op|Exprs] }, S);

translate_macro({ Op, Line, Exprs }, S) when is_list(Exprs),
    Op == '+'   orelse Op == '-'   orelse Op == '*'   orelse Op == '/' orelse
    Op == '++'  orelse Op == 'not' orelse Op == 'and' orelse Op == 'or' orelse
    Op == 'xor' orelse Op == '<'   orelse Op == '>'   orelse Op == '<=' orelse
    Op == '>='  orelse Op == '=='  orelse Op == '!='  orelse Op == '===' orelse
    Op == '!==' ->
  translate_each({ '__op__', Line, [Op|Exprs] }, S);

translate_macro({ '!', Line, [{ '!', _, [Expr] }] }, S) ->
  { TExpr, SE } = translate_each(Expr, S),
  { elixir_tree_helpers:convert_to_boolean(Line, TExpr, true, S#elixir_scope.context == guard), SE };

translate_macro({ '!', Line, [Expr] }, S) ->
  { TExpr, SE } = translate_each(Expr, S),
  { elixir_tree_helpers:convert_to_boolean(Line, TExpr, false, S#elixir_scope.context == guard), SE };

translate_macro({ in, Line, [Left, Right] }, #elixir_scope{extra_guards=nil} = S) ->
  { _, TExpr, TS } = translate_in(Line, Left, Right, S),
  { TExpr, TS };

translate_macro({ in, Line, [Left, Right] }, #elixir_scope{extra_guards=Extra} = S) ->
  { TVar, TExpr, TS } = translate_in(Line, Left, Right, S),
  { TVar, TS#elixir_scope{extra_guards=[TExpr|Extra]} };

%% Functions

translate_macro({ function, Line, [[{do,{ '->',_,Pairs}}]] }, S) ->
  assert_no_assign_or_guard_scope(Line, 'function', S),
  elixir_translator:translate_fn(Line, Pairs, S);

translate_macro({ function, Line, [_] }, S) ->
  assert_no_assign_or_guard_scope(Line, 'function', S),
  syntax_error(Line, S#elixir_scope.file, "invalid args for function");

translate_macro({ function, Line, [_, _] = Args }, S) ->
  assert_no_assign_or_guard_scope(Line, 'function', S),

  case translate_args(Args, S) of
    { [{atom,_,Name}, {integer,_,Arity}], SA } ->
      case elixir_dispatch:import_function(Line, Name, Arity, SA) of
        false -> syntax_error(Line, S#elixir_scope.file, "cannot convert a macro to a function");
        Else  -> Else
      end;
    _ ->
      syntax_error(Line, S#elixir_scope.file, "cannot dynamically retrieve local function. use function(module, fun, arity) instead")
  end;

translate_macro({ function, Line, [_,_,_] = Args }, S) when is_list(Args) ->
  assert_no_assign_or_guard_scope(Line, 'function', S),
  { [A,B,C], SA } = translate_args(Args, S),
  { { 'fun', Line, { function, A, B, C } }, SA };

%% @

translate_macro({'@', Line, [{ Name, _, Args }]}, S) when Name == typep; Name == type; Name == spec; Name == callback ->
  case elixir_compiler:get_opt(internal) of
    true  -> { { nil, Line }, S };
    false ->
      Call = { { '.', Line, ['Elixir.Kernel.Typespec', spec_to_macro(Name)] }, Line, Args },
      translate_each(Call, S)
  end;

translate_macro({'@', Line, [{ Name, _, Args }]}, S) ->
  assert_module_scope(Line, '@', S),

  case is_reserved_data(Name) andalso elixir_compiler:get_opt(internal) of
    true ->
      { { nil, Line }, S };
    _ ->
      case Args of
        [Arg] ->
          case S#elixir_scope.function of
            nil ->
              translate_each({
                { '.', Line, ['Elixir.Module', add_attribute] },
                  Line,
                  [ { '__MODULE__', Line, false }, Name, Arg ]
              }, S);
            _  ->
              syntax_error(Line, S#elixir_scope.file,
                "cannot dynamically set attribute @~s inside a function", [Name])
          end;
        _ when is_atom(Args) or (Args == []) ->
          case S#elixir_scope.function of
            nil ->
              translate_each({
                { '.', Line, ['Elixir.Module', read_attribute] },
                Line,
                [ { '__MODULE__', Line, false }, Name ]
              }, S);
            _ ->
              Contents = 'Elixir.Module':read_attribute(S#elixir_scope.module, Name),
              { elixir_tree_helpers:abstract_syntax(Contents), S }
          end;
        _ ->
          syntax_error(Line, S#elixir_scope.file, "expected 0 or 1 argument for @~s, got: ~p", [Name, length(Args)])
      end
  end;

%% Case

translate_macro({'case', Line, [Expr, KV]}, S) ->
  assert_no_assign_or_guard_scope(Line, 'case', S),
  Clauses = elixir_clauses:get_pairs(Line, do, KV, S),
  { TExpr, NS } = translate_each(Expr, S),

  RClauses = case elixir_tree_helpers:returns_boolean(TExpr) of
    true  -> rewrite_case_clauses(Clauses);
    false -> Clauses
  end,

  { TClauses, TS } = elixir_clauses:match(Line, RClauses, NS),
  { { 'case', Line, TExpr, TClauses }, TS };

%% Try

translate_macro({'try', Line, [Clauses]}, RawS) ->
  S = RawS#elixir_scope{noname=true},
  assert_no_assign_or_guard_scope(Line, 'try', S),

  Do = proplists:get_value('do', Clauses, []),
  { TDo, SB } = translate([Do], S),

  Catch = [Tuple || { X, _ } = Tuple <- Clauses, X == 'rescue' orelse X == 'catch'],
  { TCatch, SC } = elixir_try:clauses(Line, Catch, umergec(S, SB)),

  { TAfter, SA } = case orddict:find('after', Clauses) of
    { ok, After } -> translate([After], umergec(S, SC));
    error -> { [], SC }
  end,

  { { 'try', Line, unpack(TDo), [], TCatch, unpack(TAfter) }, umergec(RawS, SA) };

%% Receive

translate_macro({'receive', Line, [KV] }, S) ->
  assert_no_assign_or_guard_scope(Line, 'receive', S),
  Do = elixir_clauses:get_pairs(Line, do, KV, S, true),

  case orddict:is_key('after', KV) of
    true ->
      After = elixir_clauses:get_pairs(Line, 'after', KV, S),
      { TClauses, SC } = elixir_clauses:match(Line, Do ++ After, S),
      { FClauses, TAfter } = elixir_tree_helpers:split_last(TClauses),
      { _, _, [FExpr], _, FAfter } = TAfter,
      { { 'receive', Line, FClauses, FExpr, FAfter }, SC };
    false ->
      { TClauses, SC } = elixir_clauses:match(Line, Do, S),
      { { 'receive', Line, TClauses }, SC }
  end;

%% Definitions

translate_macro({defmodule, Line, [Ref, KV]}, S) ->
  { TRef, _ } = translate_each(Ref, S),

  Block = case orddict:find(do, KV) of
    { ok, DoValue } -> DoValue;
    error -> syntax_error(Line, S#elixir_scope.file, "expected do: argument in defmodule")
  end,

  { FRef, FS } = case TRef of
    { atom, _, Module } ->
      NewModule = module_ref(Ref, Module, S#elixir_scope.module),

      RS = case Module == NewModule of
        true  -> S;
        false ->
          element(2, translate_each({
            alias, Line, [NewModule, [{as, elixir_aliases:first(Module)}]]
          }, S))
      end,

      {
        { atom, Line, NewModule },
        RS#elixir_scope{scheduled=[NewModule|S#elixir_scope.scheduled]}
      };
    _ ->
      { TRef, S }
  end,

  { elixir_module:translate(Line, FRef, Block, S), FS };

translate_macro({Kind, Line, [Call]}, S) when ?FUNS() ->
  translate_macro({Kind, Line, [Call, skip_definition]}, S);

translate_macro({Kind, Line, [Call, Expr]}, S) when ?FUNS() ->
  assert_module_scope(Line, Kind, S),
  assert_no_function_scope(Line, Kind, S),
  { TCall, Guards } = elixir_clauses:extract_guards(Call),
  { Name, Args }    = elixir_clauses:extract_args(TCall),
  TName             = elixir_tree_helpers:abstract_syntax(Name),
  TArgs             = elixir_tree_helpers:abstract_syntax(Args),
  TGuards           = elixir_tree_helpers:abstract_syntax(Guards),
  TExpr             = elixir_tree_helpers:abstract_syntax(Expr),
  { elixir_def:wrap_definition(Kind, Line, TName, TArgs, TGuards, TExpr, S), S };

translate_macro({Kind, Line, [Name, Args, Guards, Expr]}, S) when ?FUNS() ->
  assert_module_scope(Line, Kind, S),
  assert_no_function_scope(Line, Kind, S),
  { TName, NS }   = translate_each(Name, S),
  { TArgs, AS }   = translate_each(Args, NS),
  { TGuards, TS } = translate_each(Guards, AS),
  TExpr           = elixir_tree_helpers:abstract_syntax(Expr),
  { elixir_def:wrap_definition(Kind, Line, TName, TArgs, TGuards, TExpr, TS), TS };

%% Apply - Optimize apply by checking what doesn't need to be dispatched dynamically

translate_macro({ apply, Line, [Left, Right, Args] }, S) when is_list(Args) ->
  { TLeft,  SL } = translate_each(Left, S),
  { TRight, SR } = translate_each(Right, umergec(S, SL)),
  translate_apply(Line, TLeft, TRight, Args, S, SL, SR);

translate_macro({ apply, Line, Args }, S) ->
  { TArgs, NS } = translate_args(Args, S),
  { ?ELIXIR_WRAP_CALL(Line, erlang, apply, TArgs), NS };

%% Handle forced variables

translate_macro({ 'var!', _, [{Name, Line, Atom}] }, S) when is_atom(Name), is_atom(Atom) ->
  elixir_scope:translate_var(Line, Name, S);

translate_macro({ 'var!', Line, [_] }, S) ->
  syntax_error(Line, S#elixir_scope.file, "invalid args for var!").

%% HELPERS

translate_in(Line, Left, Right, S) ->
  { TLeft, SL } = case Left of
    { '_', _, Atom } when is_atom(Atom) ->
      elixir_scope:build_erl_var(Line, S);
    _ ->
      translate_each(Left, S)
  end,

  { TRight, SR } = translate_each(Right, SL),

  Cache = (S#elixir_scope.context == nil),

  { Var, SV } = case Cache of
    true  -> elixir_scope:build_erl_var(Line, SR);
    false -> { TLeft, SR }
  end,

  Expr = case TRight of
    { cons, _, _, _ } ->
      [H|T] = elixir_tree_helpers:cons_to_list(TRight),
      lists:foldl(fun(X, Acc) ->
        { op, Line, 'orelse', Acc, { op, Line, '==', Var, X } }
      end, { op, Line, '==', Var, H }, T);
    { tuple, _, [{ atom, _, 'Elixir.Range' }, Start, End] } ->
      { op, Line, 'andalso',
        { op, Line, '>=', Var, Start },
        { op, Line, '=<', Var, End }
      };
    _ ->
      syntax_error(Line, S#elixir_scope.file, "invalid args for operator in")
  end,

  case Cache of
    true  -> { Var, { block, Line, [ { match, Line, Var, TLeft }, Expr ] }, SV };
    false -> { Var, Expr, SV }
  end.

rewrite_case_clauses([{do,[{in,_,[{'_',_,_},[false,nil]]}],False},{do,[{'_',_,_}],True}]) ->
  [{do,[false],False},{do,[true],True}];

rewrite_case_clauses(Clauses) ->
  Clauses.

module_ref(_Raw, Module, nil) ->
  Module;

module_ref({ '__aliases__', _, ['Elixir'|_]}, Module, _Nesting) ->
  Module;

module_ref(_F, Module, Nesting) ->
  elixir_aliases:concat([Nesting, Module]).

is_reserved_data(moduledoc) -> true;
is_reserved_data(doc)       -> true;
is_reserved_data(_)         -> false.

spec_to_macro(type)     -> deftype;
spec_to_macro(typep)    -> deftypep;
spec_to_macro(spec)     -> defspec;
spec_to_macro(callback) -> defcallback.

% Unpack a list of expressions from a block.
unpack([{ '__block__', _, Exprs }]) -> Exprs;
unpack(Exprs)                       -> Exprs.
