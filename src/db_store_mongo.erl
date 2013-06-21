%%
%% db_store_mongo.erl
%% Kevin Lynx
%% 06.16.2013
%%
-module(db_store_mongo).
-include("vlog.hrl").
-export([init/2,
		 close/1,
		 insert/5,
		 count/1,
		 inc_announce/2,
		 exist/2,
		 index/2,
		 search_announce_top/2,
		 search_recently/2,
		 search/2]).
-compile(export_all).
-define(DBNAME, torrents).
-define(COLLNAME, hashes).
-define(SEARCH_COL, name_array).

init(Host, Port) ->
	{ok, Conn} = mongo_connection:start_link({Host, Port}),
	?I(?FMT("connect mongodb ~p:~p success", [Host, Port])),
	enable_text_search(Conn),
	ensure_search_index(Conn),
	Conn.

close(Conn) ->
	mongo_connection:stop(Conn).

count(Conn) ->
	mongo_do(Conn, fun() ->
		mongo:count(?COLLNAME, {})
	end).

exist(Conn, Hash) when is_list(Hash) ->
	case find_exist(Conn, Hash) of
		{} -> false;
		_ -> true
	end.

% {Rets, {Found, CostTime}}
search(Conn, Key) when is_list(Key) ->
	BinColl = list_to_binary(atom_to_list(?COLLNAME)),
	BinKey = list_to_binary(Key),
	Ret = mongo_do(Conn, fun() ->
		mongo:command({text, BinColl, search, BinKey})
	end),
	{decode_search(Ret), decode_search_stats(Ret)}.

search_announce_top(Conn, Count) ->
	Sel = {'$query', {}, '$orderby', {announce, -1}},
	List = mongo_do(Conn, fun() ->
		% mongodb-erlang does not provide cursor.limit()/sort() functions, wired
		% but it work here
		Cursor = mongo:find(?COLLNAME, Sel, [], 0, Count), 
		mongo_cursor:rest(Cursor)
	end),
	[decode_torrent_item(Item) || Item <- List].
 
% db.hashes.find({$query:{},$orderby:{created_at: 1}}).limit(10);
search_recently(Conn, Count) ->
	Sel = {'$query', {}, '$orderby', {created_at, -1}},
	List = mongo_do(Conn, fun() ->
		Cursor = mongo:find(?COLLNAME, Sel, [], 0, Count), 
		mongo_cursor:rest(Cursor)
	end),
	[decode_torrent_item(Item) || Item <- List].

index(Conn, Hash) when is_list(Hash) ->
	Ret = mongo_do(Conn, fun() ->
		mongo:find_one(?COLLNAME, {'_id', list_to_binary(Hash)})
	end),
	case Ret of 
		{} -> {};
		{Torrent} -> decode_torrent_item(Torrent)
	end.

insert(Conn, Hash, Name, Length, Files) when is_list(Hash) ->
	case find_exist(Conn, Hash) of
		{} -> 
			NewDoc = create_torrent_desc(Hash, Name, Length, 1, Files),
			Ret = mongo_do(Conn, fun() ->
				mongo:insert(?COLLNAME, NewDoc)
			end),
			{new, Ret};
		{Doc} ->
			{Announce} = bson:lookup(announce, Doc),	
			true = is_integer(Announce),
			NewDoc = create_torrent_desc(Hash, Name, Length, Announce + 1, Files),
			Ret = mongo_do(Conn, fun() ->
				mongo:delete(?COLLNAME, hash_selector(Hash)),
				mongo:insert(?COLLNAME, NewDoc)
				% update will not overwrite the old one, don't know the reason yet
				%mongo:update(?COLLNAME, hash_selector(Hash), NewDoc)
			end),
			{update, Ret}
	end.

inc_announce(Conn, Hash) when is_list(Hash) ->
	% damn, mongodb-erlang doesnot support update a field for an object,
	% `findAndModify` works but it will change `announce' datatype to double
	Cmd = {findAndModify, ?COLLNAME, query, {'_id', list_to_binary(Hash)}, 
		update, {'$inc', {announce, 1}},
		new, true},
	Ret = mongo_do(Conn, fun() ->
		mongo:command(Cmd)
	end),
	case Ret of
		{value, undefined, ok, 1.0} -> false;
		{value, _Obj, lastErrorObject, {updatedExisting, true, n, 1}, ok, 1.0} -> true;
		_ -> false
	end.

ensure_search_index(Conn) ->
	Spec = {key, {?SEARCH_COL, <<"text">>}},
	mongo_do(Conn, fun() ->
		mongo:ensure_index(?COLLNAME, Spec)
	end).

% not work
enable_text_search(Conn) ->
	Cmd = {setParameter, 1, textSearchEnabled, true},
	mongo:do(safe, master, Conn, admin, fun() ->
		mongo:command(Cmd)
	end).

create_torrent_desc(Hash, Name, Length, Announce, Files) ->
	NameArray = case string_split:split(Name) of
		{error, L, D} ->
			?E(?FMT("string split failed(error): ~p ~p", [L, D])),
			[Name];
		{incomplete, L, D} ->
			?E(?FMT("string split failed(incomplte): ~p ~p", [L, D])),
			[Name];
		{ok, R} -> R 
	end,
	{'_id', list_to_binary(Hash),
	  name, list_to_binary(Name),
	  name_array, NameArray,
	  length, Length,
	  created_at, time_util:now_seconds(),
	  announce, Announce,
	  files, encode_file_list(Files)}.

% {file1, {name, xx, length, xx}, file2, {name, xx, length, xx}}
encode_file_list(Files) ->
	Keys = ["file"++integer_to_list(Index) || Index <- lists:seq(1, length(Files))],
	Generator = lists:zip(Keys, Files),
	list_to_tuple(lists:flatten([[list_to_atom(Key), {name, list_to_binary(Name), length, Length}]
		|| {Key, {Name, Length}} <- Generator])).

find_exist(Conn, Hash) ->
	mongo_do(Conn, fun() ->
		mongo:find_one(?COLLNAME, hash_selector(Hash))
	end).

mongo_do(Conn, Fun) ->
	mongo:do(safe, master, Conn, ?DBNAME, Fun).

% TODO: replace this with {'_id', ID}
hash_selector(Hash) ->
	Expr = lists:flatten(io_lib:format("this._id == '~s'", [Hash])),
	{'$where', list_to_binary(Expr)}.

decode_search_stats(Rets) ->
	{Stats} = bson:lookup(stats, Rets),
	{Found} = bson:lookup(nfound, Stats),
	{Cost} = bson:lookup(timeMicros, Stats),
	{Found, Cost}.

decode_search(Rets) ->
	case bson:lookup(results, Rets) of
		{} ->
			[];
		{List} ->
			[decode_ret_item(Item) || Item <- List]
	end.

decode_ret_item(Item) ->
	{Torrent} = bson:lookup(obj, Item),
	decode_torrent_item(Torrent).

decode_torrent_item(Torrent) ->	
	{BinHash} = bson:lookup('_id', Torrent),
	Hash = binary_to_list(BinHash),
	{BinName} = bson:lookup(name, Torrent),
	Name = binary_to_list(BinName),
	{Length} = bson:lookup(length, Torrent),
	{CreatedT} = bson:lookup(created_at, Torrent),
	ICreatedAt = round(CreatedT),
	{Announce} = bson:lookup(announce, Torrent),
	IA = round(Announce), % since announce maybe double in mongodb
	case bson:lookup(files, Torrent) of
		{{}} ->
			{single, Hash, {Name, Length}, IA, ICreatedAt};
		{Files} ->
			{multi, Hash, {Name, decode_files(tuple_to_list(Files))}, IA, ICreatedAt}
	end.
 
decode_files(Files) ->
	decode_file(Files).

decode_file([_|[File|Rest]]) ->
	{BinName} = bson:lookup(name, File),
	Name = binary_to_list(BinName),
	{Length} = bson:lookup(length, File),
	[{Name, Length}] ++ decode_file(Rest);

decode_file([]) ->
	[].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
test_insert() ->
	Conn = init(localhost, 27017),
	insert(Conn, "7C6932E7EC1CF5B00AE991871E57B2375DADA5A9", "movie 1", 128, []),
	insert(Conn, "AE94E340B5234C8410F37CFA7170F8C5657ECE5D", "another movie name", 0, 
		[{"subfile-a", 100}, {"subfile-b", 80}]),
	insert(Conn, "0F1B5BE407E130AEEA8AB2964F5100190086ED93", "oh it work", 2456, []),
	close(Conn).

test_content(Fun) ->
	Conn = init(localhost, 27017),
	Ret = Fun(Conn),
	close(Conn),
	Ret.

test_ensureidx() ->
	test_content(fun(Conn) ->
		enable_text_search(Conn),
		ensure_search_index(Conn)
	end).

test_search(Key) ->
	test_content(fun(Conn) ->
		search(Conn, Key)
	end).

test_tmpsearch(Key) ->
	test_content(fun(Conn) ->
		BinColl = list_to_binary(atom_to_list(?COLLNAME)),
		BinKey = list_to_binary(Key),
		Ret = mongo_do(Conn, fun() ->
			mongo:command({text, BinColl, search, BinKey})
		end),
		Ret
	end).

test_count() ->
	test_content(fun(Conn) ->
		count(Conn)
	end).

test_find_top() ->
	test_content(fun(Conn) ->
		search_announce_top(Conn, 2)
	end).

test_announce() ->
	Hash = "F79ED3E2BF29A5C4358202E88C9983AB479D7722",
	test_content(fun(Conn) ->
		inc_announce(Conn, Hash)
	end).

test_index(Hash) ->
	test_content(fun(Conn) ->
		index(Conn, Hash)
	end).


