% Holds the logic responsible for methods definition during parse time.
% For modules introspection, check elixir_methods.
-module(elixir_def_method).
-export([unpack_default_clause/2, is_empty_table/1, new_method_table/1,
  wrap_method_definition/5, store_wrapped_method/4, unwrap_stored_methods/1]).
-include("elixir.hrl").

% Returns if a given table is empty or not.
%
% Since we use the same method table to store the current visibility,
% public, protected and callbacks method, the table is empty if its
% size is 4.
is_empty_table(MethodTable) ->
  case ets:info(MethodTable, size) of
    4 -> true;
    _ -> false
  end.

% Creates a new method table for the given name.
new_method_table(Name) ->
  MethodTable = ?ELIXIR_ATOM_CONCAT([mex_, Name]),
  ets:new(MethodTable, [set, named_table, private]),
  ets:insert(MethodTable, { public, [] }),
  ets:insert(MethodTable, { protected, [] }),
  ets:insert(MethodTable, { callbacks, [] }),
  ets:insert(MethodTable, { visibility, public }),
  MethodTable.

% Wraps the method into a call that will call store_wrapped_method
% once the method definition is read. The method is compiled into a
% meta tree to ensure we will receive the full method.
%
% We need to wrap methods instead of eagerly defining them to ensure
% functions inside if branches won't propagate, for example:
%
%   module Foo
%     if false
%       def bar; 1; end
%     else
%       def bar; 2; end
%     end
%   end
%
% If we just analyzed the compiled structure (i.e. the method availables
% before evaluating the method body), we would see both definitions.
wrap_method_definition(Name, Line, Filename, Method, Defaults) ->
  Meta = abstract_syntax(Method),
  MetaDefaults = abstract_syntax(Defaults),
  Content = [{atom, Line, Name}, {string, Line, Filename}, Meta, MetaDefaults],
  ?ELIXIR_WRAP_CALL(Line, ?MODULE, store_wrapped_method, Content).

% Gets a module stored in the CompiledTable with Index and
% move it to the AddedTable.
store_wrapped_method(Module, Filename, Method, Defaults) ->
  Name = element(3, Method),
  MethodTable = ?ELIXIR_ATOM_CONCAT([mex_, Module]),
  Visibility = ets:lookup_element(MethodTable, visibility, 2),
  [store_each_method(MethodTable, Visibility, Filename, function_from_default(Name, Default)) || Default <- Defaults],
  store_each_method(MethodTable, Visibility, Filename, Method).

function_from_default(Name, { clause, Line, Args, _Guards, _Exprs } = Clause) ->
  { function, Line, Name, length(Args), [Clause] }.

store_each_method(MethodTable, Visibility, Filename, {function, Line, Name, Arity, Clauses}) ->
  FinalClauses = case ets:lookup(MethodTable, {Name, Arity}) of
    [{{Name, Arity}, FinalLine, OtherClauses}] ->
      check_valid_visibility(Line, Filename, Name, Arity, Visibility, MethodTable),
      Clauses ++ OtherClauses;
    [] ->
      add_visibility_entry(Name, Arity, Visibility, MethodTable),
      FinalLine = Line,
      Clauses
  end,
  ets:insert(MethodTable, {{Name, Arity}, FinalLine, FinalClauses}).

% Helper to unwrap the methods stored in the methods table. It also returns
% a list of methods to be exported with all protected methods.
unwrap_stored_methods(Table) ->
  Public    = ets:lookup_element(Table, public, 2),
  Protected = ets:lookup_element(Table, protected, 2),
  Callbacks = ets:lookup_element(Table, callbacks, 2),
  ets:delete(Table, visibility),
  ets:delete(Table, public),
  ets:delete(Table, protected),
  ets:delete(Table, callbacks),
  AllProtected = Protected ++ Callbacks,
  { Callbacks, { Public ++ AllProtected, AllProtected, ets:foldl(fun unwrap_stored_method/2, [], Table) } }.

unwrap_stored_method({{Name, Arity}, Line, Clauses}, Acc) ->
  [{function, Line, Name, Arity, lists:reverse(Clauses)}|Acc].

% Unpack default args from the given clause
unpack_default_clause(Name, Clause) ->
  { NewArgs, NewClauses } = unpack_default_args(Name, element(3, Clause), [], []),
  { setelement(3, Clause, NewArgs), NewClauses }.

% Unpack default args from clauses
unpack_default_args(Name, [{default_arg, Line, Expr, Default}|T] = List, Acc, Clauses) ->
  Args = build_arg(length(Acc), Line, []),
  Defaults = lists:map(fun extract_default/1, List),
  Clause = { clause, Line, Args, [], [
    { call, Line, {atom, Line, Name}, Args ++ Defaults }
  ]},
  unpack_default_args(Name, T, [Expr|Acc], [Clause|Clauses]);

unpack_default_args(Name, [H|T], Acc, Clauses) ->
  unpack_default_args(Name, T, [H|Acc], Clauses);

unpack_default_args(_Name, [], Acc, Clauses) ->
  { lists:reverse(Acc), lists:reverse(Clauses) }.

% Extract default values
extract_default({default_arg, Line, Expr, Default}) ->
  Default.

% Build an args list
build_arg(0, _Line, Acc) -> Acc;

build_arg(Counter, Line, Acc) ->
  Var = { var, Line, ?ELIXIR_ATOM_CONCAT(["X", Counter]) },
  build_arg(Counter - 1, Line, [Var|Acc]).

% Check the visibility of the method with the given Name and Arity in the attributes table.
add_visibility_entry(Name, Arity, private, Table) ->
  [];

add_visibility_entry(Name, Arity, Visibility, Table) ->
  Current= ets:lookup_element(Table, Visibility, 2),
  ets:insert(Table, {Visibility, [{Name, Arity}|Current]}).

check_valid_visibility(Line, Filename, Name, Arity, Visibility, Table) ->
  Available = [public, protected, callbacks, private],
  PrevVisibility = find_visibility(Name, Arity, Available, Table),
  case Visibility == PrevVisibility of
    false -> elixir_errors:handle_file_warning(Filename, {Line, ?MODULE, {changed_visibility, {Name, PrevVisibility}}});
    true -> []
  end.

find_visibility(Name, Arity, [H|[]], Table) ->
  H;

find_visibility(Name, Arity, [Visibility|T], Table) ->
  List = ets:lookup_element(Table, Visibility, 2),
  case lists:member({Name, Arity}, List) of
    true  -> Visibility;
    false -> find_visibility(Name, Arity, T, Table)
  end.

abstract_syntax(Tree) ->
  erl_syntax:revert(erl_syntax:abstract(Tree)).