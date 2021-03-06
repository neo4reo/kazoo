%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2017, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(crossbar_doc).

-export([load/2, load/3
        ,load_from_file/2
        ,load_merge/2, load_merge/3, load_merge/4
        ,merge/3
        ,patch_and_validate/3
        ,load_view/3, load_view/4, load_view/5, load_view/6
        ,load_attachment/4, load_docs/2
        ,save/1, save/2
        ,delete/1, delete/2
        ,save_attachment/4, save_attachment/5
        ,delete_attachment/3
        ,ensure_saved/1, ensure_saved/2
        ,rev_to_etag/1
        ,current_doc_vsn/0
        ,update_pvt_parameters/2
        ,start_key/1, start_key/2
        ,pagination_page_size/0, pagination_page_size/1
        ,has_qs_filter/1
        ,filtered_doc_by_qs/2, filtered_doc_by_qs/3
        ]).

-export([handle_json_success/2]).
-export([handle_datamgr_success/2
        ,handle_datamgr_errors/3
        ]).

-ifdef(TEST).
-export([filter_doc_by_querystring/2]).
-endif.

-export_type([view_options/0
             ,load_options/0
             ,startkey/0
             ]).

-include("crossbar.hrl").

-define(CROSSBAR_DOC_VSN, <<"1">>).
-define(PVT_FUNS, [fun add_pvt_vsn/2
                  ,fun add_pvt_account_id/2
                  ,fun add_pvt_account_db/2
                  ,fun add_pvt_created/2
                  ,fun add_pvt_modified/2
                  ,fun add_pvt_request_id/2
                  ,fun add_pvt_auth/2
                  ]).

-define(PAGINATION_PAGE_SIZE
       ,kapps_config:get_integer(?CONFIG_CAT
                                ,<<"pagination_page_size">>
                                ,50
                                )
       ).

-type direction() :: 'ascending' | 'descending'.

-type startkey() :: kz_json:api_json_term().

-type startkey_fun() :: 'undefined' |
                        fun((cb_context:context()) -> startkey()) |
                        fun((kz_proplist(), cb_context:context()) -> startkey()).

-type view_options() :: kazoo_data:view_options() |
                        [{'databases', ne_binaries()} |
                         {'startkey_fun', startkey_fun()}
                        ].

-type load_option() :: {?OPTION_EXPECTED_TYPE, ne_binary()} |
                       {'use_cache', boolean()}.
-type load_options() :: kazoo_data:view_options() |
                        [load_option()].

-record(load_view_params, {view :: api_binary()
                          ,view_options = [] :: view_options()
                          ,context :: cb_context:context()
                          ,start_key :: startkey()
                          ,page_size :: non_neg_integer() | api_binary()
                          ,filter_fun :: filter_fun()
                          ,dbs = [] :: ne_binaries()
                          ,direction = 'ascending' :: direction()
                          }).
-type load_view_params() :: #load_view_params{}.

-spec pagination_page_size() -> pos_integer().
-spec pagination_page_size(cb_context:context()) -> api_pos_integer().
-spec pagination_page_size(cb_context:context(), ne_binary()) -> api_pos_integer().
pagination_page_size() ->
    ?PAGINATION_PAGE_SIZE.

pagination_page_size(Context) ->
    pagination_page_size(Context, cb_context:api_version(Context)).

pagination_page_size(_Context, ?VERSION_1) -> 'undefined';
pagination_page_size(Context, _Version) ->
    case cb_context:req_value(Context, <<"page_size">>) of
        'undefined' -> pagination_page_size();
        V -> kz_util:to_integer(V)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Returns the version number attached to created/updated documents.
%% Indicates what pvt fields are created/updated when saving.
%%
%% Failure here returns 410, 500, or 503
%% @end
%%--------------------------------------------------------------------
-spec current_doc_vsn() -> ne_binary().
current_doc_vsn() -> ?CROSSBAR_DOC_VSN.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to load the context with account details,
%% including the account db name and the account doc.
%%
%% Failure here returns 410, 500, or 503
%% @end
%%--------------------------------------------------------------------
-spec load(kazoo_data:docid() | kazoo_data:docids(), cb_context:context()) ->
                  cb_context:context().
-spec load(kazoo_data:docid() | kazoo_data:docids(), cb_context:context(), load_options()) ->
                  cb_context:context().
-spec load(ne_binary() | ne_binaries(), cb_context:context(), load_options(), crossbar_status()) ->
                  cb_context:context().

load({DocType, DocId}, Context) ->
    load(DocId, Context, [{'doc_type', DocType}]);
load(DocId, Context) ->
    load(DocId, Context, []).

load({DocType, DocId}, Context, Options) ->
    load(DocId, Context, [{'doc_type', DocType} | Options]);
load(DocId, Context, Options) ->
    load(DocId, Context, Options, cb_context:resp_status(Context)).

load(_DocId, Context, _Options, 'error') -> Context;
load(DocId, Context, Options, _RespStatus) when is_binary(DocId) ->
    OpenFun = get_open_function(Options),
    case OpenFun(cb_context:account_db(Context), DocId, Options) of
        {'error', Error} ->
            handle_datamgr_errors(Error, DocId, Context);
        {'ok', JObj} ->
            case check_document_type(Context, JObj, Options) of
                'true' -> handle_successful_load(Context, JObj);
                'false' ->
                    ErrorCause = kz_json:from_list([{<<"cause">>, DocId}]),
                    cb_context:add_system_error('bad_identifier', ErrorCause, Context)
            end
    end;
load([], Context, _Options, _RespStatus) ->
    cb_context:add_system_error('bad_identifier',  Context);
load([_|_]=IDs, Context, Opts, _RespStatus) ->
    Opts1 = [{'keys', IDs}, 'include_docs' | Opts],
    case kz_datamgr:all_docs(cb_context:account_db(Context), Opts1) of
        {'error', Error} -> handle_datamgr_errors(Error, IDs, Context);
        {'ok', JObjs} ->
            Docs = extract_included_docs(JObjs),
            case check_document_type(Context, Docs, Opts) of
                'true' ->
                    cb_context:store(handle_datamgr_success(Docs, Context), 'db_doc', Docs);
                'false' ->
                    ErrorCause = kz_json:from_list([{<<"cause">>, IDs}]),
                    cb_context:add_system_error('bad_identifier', ErrorCause, Context)
            end
    end.

-spec get_open_function(kz_proplist()) -> function().
get_open_function(Options) ->
    case props:get_is_true('use_cache', Options, 'true') of
        'true' ->  fun kz_datamgr:open_cache_doc/3;
        'false' -> fun kz_datamgr:open_doc/3
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns 'true' or 'false' if the requested document type is matched
%% against the actual document type or the name of the last resource
%% that request it. It first checks expected type is matched with document
%% type, if it fails it checks document type with the name of the
%% last resource. If the document doesn't have a `pvt_type`
%% property or the resource requested that expected type to be `any`,
%% it will return `true`.
%% @end
%%--------------------------------------------------------------------
-spec check_document_type(cb_context:context(), kz_json:object() | kz_json:objects(), kz_proplist()) ->
                                 boolean().
check_document_type(_Context, [], _Options) ->
    'true';
check_document_type(Context, [_|_]=JObjs, Options) ->
    lists:all(fun(JObj) -> check_document_type(Context, JObj, Options) end
             ,JObjs
             );
check_document_type(Context, JObj, Options) ->
    JObjType = kz_doc:type(JObj),
    ExpectedType = props:get_value(?OPTION_EXPECTED_TYPE, Options),
    [{Noun, _}| _] = cb_context:req_nouns(Context),
    ReqType = normalize_requested_resource_name(Noun),
    document_type_match(JObjType, ExpectedType, ReqType).

-spec document_type_match(api_binary(), api_binary(), ne_binary()) -> boolean().
document_type_match('undefined', _ExpectedType, _ReqType) ->
    lager:debug("document doesn't have type, requested type is ~p", [_ReqType]),
    'true';
document_type_match(_JObjType, <<"any">>, _) -> 'true';
document_type_match(ExpectedType, ExpectedTypes, _)
  when is_list(ExpectedTypes) ->
    lists:member(ExpectedType, ExpectedTypes);
document_type_match(ExpectedType, ExpectedType, _) -> 'true';
document_type_match(ReqType, _, ReqType) ->
    lager:debug("expected type is not specified, checking against requested type ~p", [ReqType]),
    'true';
document_type_match(_JObjType, _ExpectedType, _ReqType) ->
    lager:warning("the document type ~s does not match the expected type ~s nor the requested type ~s"
                 ,[_JObjType, _ExpectedType, _ReqType]
                 ),
    'false'.

-spec normalize_requested_resource_name(ne_binary()) -> ne_binary().
normalize_requested_resource_name(Name) ->
    case props:get_value(Name, ?SPECIAL_EXPECTED_TYPE) of
        'undefined' -> depluralize_resource_name(Name);
        Special -> Special
    end.

-spec depluralize_resource_name(ne_binary()) -> ne_binary().
depluralize_resource_name(Name) ->
    Size = byte_size(Name) - 1,
    case Name of
        <<Bin:Size/binary, "s">> -> Bin;
        Bin -> Bin
    end.

-spec handle_successful_load(cb_context:context(), kz_json:object()) -> cb_context:context().
-spec handle_successful_load(cb_context:context(), kz_json:object(), boolean()) -> cb_context:context().
handle_successful_load(Context, JObj) ->
    handle_successful_load(Context, JObj, kz_doc:is_soft_deleted(JObj)).

handle_successful_load(Context, JObj, 'true') ->
    lager:debug("doc ~s(~s) is soft-deleted, returning bad_identifier"
               ,[kz_doc:id(JObj), kz_doc:revision(JObj)]
               ),
    cb_context:add_system_error('bad_identifier'
                               ,kz_json:from_list([{<<"cause">>, kz_doc:id(JObj)}])
                               ,Context
                               );
handle_successful_load(Context, JObj, 'false') ->
    lager:debug("loaded doc ~s(~s) from ~s"
               ,[kz_doc:id(JObj), kz_doc:revision(JObj), cb_context:account_db(Context)]
               ),
    cb_context:store(handle_datamgr_success(JObj, Context), 'db_doc', JObj).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% "Load" is a poor word choice given the other function names...
%% This function creates a crossbar document from the contents of
%% a file.
%%
%% Failure here returns 410, 500, or 503
%% @end
%%--------------------------------------------------------------------
-spec load_from_file(ne_binary(), ne_binary()) ->
                            {'ok', kz_json:object()} |
                            {'error', atom()}.
load_from_file(Db, File) ->
    kz_datamgr:load_doc_from_file(Db, 'crossbar', File).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to merge the submitted data with the private
%% fields of an existing account document, if successful it will
%% load the context with the account details
%%
%% Failure here returns 410, 500, or 503
%% @end
%%--------------------------------------------------------------------
-spec load_merge(ne_binary(), cb_context:context()) ->
                        cb_context:context().
-spec load_merge(ne_binary(), cb_context:context(), kz_proplist()) ->
                        cb_context:context().
-spec load_merge(ne_binary(), kz_json:object(), cb_context:context(), kz_proplist()) ->
                        cb_context:context().
-spec load_merge(ne_binary(), kz_json:object(), cb_context:context(), kz_proplist(), api_object()) ->
                        cb_context:context().

load_merge(DocId, Context) ->
    load_merge(DocId, cb_context:doc(Context), Context, []).

load_merge(DocId, Context, Options) ->
    load_merge(DocId, cb_context:doc(Context), Context, Options).

load_merge(DocId, DataJObj, Context, Options) ->
    load_merge(DocId, DataJObj, Context, Options, cb_context:load_merge_bypass(Context)).

load_merge(DocId, DataJObj, Context, Options, 'undefined') ->
    Context1 = load(DocId, Context, Options),
    case cb_context:resp_status(Context1) of
        'success' ->
            lager:debug("loaded doc ~s(~s), merging", [DocId, kz_doc:revision(cb_context:doc(Context1))]),
            merge(DataJObj, cb_context:doc(Context1), Context1);
        _Status -> Context1
    end;
load_merge(_DocId, _DataJObj, Context, _Options, BypassJObj) ->
    handle_datamgr_success(BypassJObj, Context).

-spec merge(kz_json:object(), kz_json:object(), cb_context:context()) ->
                   cb_context:context().
merge(DataJObj, JObj, Context) ->
    PrivJObj = kz_json:private_fields(JObj),
    handle_datamgr_success(kz_json:merge_jobjs(PrivJObj, DataJObj), Context).

-type validate_fun() :: fun((ne_binary(), cb_context:context()) -> cb_context:context()).

-spec patch_and_validate(ne_binary(), cb_context:context(), validate_fun()) ->
                                cb_context:context().
-spec patch_and_validate_doc(ne_binary(), cb_context:context(), validate_fun(), crossbar_status()) ->
                                    cb_context:context().
patch_and_validate(Id, Context, ValidateFun) ->
    Context1 = load(Id, Context, ?TYPE_CHECK_OPTION_ANY),
    patch_and_validate_doc(Id, Context1, ValidateFun, cb_context:resp_status(Context1)).

patch_and_validate_doc(Id, Context, ValidateFun, 'success') ->
    PubJObj = kz_doc:public_fields(cb_context:req_data(Context)),
    PatchedJObj = kz_json:merge(cb_context:doc(Context), PubJObj),
    Context1 = cb_context:set_req_data(Context, PatchedJObj),
    ValidateFun(Id, Context1);
patch_and_validate_doc(Id, Context, ValidateFun, _RespStatus) ->
    ValidateFun(Id, Context).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to load the context with the results of a view
%% run against the accounts database.
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec load_view(ne_binary() | 'all_docs', kz_proplist(), cb_context:context()) ->
                       cb_context:context().
-spec load_view(ne_binary() | 'all_docs', kz_proplist(), cb_context:context(), kz_json:json_term() | filter_fun()) ->
                       cb_context:context().
-spec load_view(ne_binary() | 'all_docs', kz_proplist(), cb_context:context(), kz_json:json_term(), pos_integer()) ->
                       cb_context:context().
-spec load_view(ne_binary() | 'all_docs', kz_proplist(), cb_context:context(), kz_json:json_term(), pos_integer(), filter_fun() | 'undefined') ->
                       cb_context:context().
load_view(View, Options, Context) ->
    load_view(View, Options, Context
             ,start_key(Options, Context)
             ,pagination_page_size(Context)
             ,'undefined'
             ).

load_view(View, Options, Context, FilterFun)
  when is_function(FilterFun, 2);
       is_function(FilterFun, 3) ->
    load_view(View, Options, Context
             ,start_key(Options, Context)
             ,pagination_page_size(Context)
             ,FilterFun
             );
load_view(View, Options, Context, StartKey) ->
    load_view(View, Options, Context, StartKey
             ,pagination_page_size(Context)
             ).

load_view(View, Options, Context, StartKey, PageSize) ->
    load_view(View, Options, Context, StartKey, PageSize, 'undefined').

load_view(View, Options, Context, StartKey, PageSize, FilterFun) ->
    load_view(#load_view_params{view=View
                               ,view_options=Options
                               ,context=cb_context:set_doc(Context, [])
                               ,start_key=StartKey
                               ,page_size=PageSize
                               ,filter_fun=FilterFun
                               ,dbs=[Db || Db <- props:get_value('databases', Options, [cb_context:account_db(Context)]),
                                           kz_datamgr:db_exists(Db, View)]
                               ,direction=view_sort_direction(Options)
                               }).

-spec view_sort_direction(kz_proplist()) -> direction().
view_sort_direction(Options) ->
    case props:get_value('descending', Options) of
        'true' -> 'descending';
        'undefined' -> 'ascending'
    end.

load_view(#load_view_params{dbs=[]
                           ,context=Context
                           }) ->
    case cb_context:resp_status(Context) of
        'success' ->
            lager:debug("databases exhausted"),
            handle_datamgr_success(cb_context:doc(Context), Context);
        _Status -> Context
    end;
load_view(#load_view_params{page_size=PageSize
                           ,context=Context
                           }) when PageSize =< 0 ->
    lager:debug("page_size exhausted: ~p", [PageSize]),
    case cb_context:resp_status(Context) of
        'success' -> handle_datamgr_success(cb_context:doc(Context), Context);
        _Status -> Context
    end;
load_view(#load_view_params{view=View
                           ,view_options=Options
                           ,context=Context
                           ,start_key=StartKey
                           ,page_size=PageSize
                           ,dbs=[Db|Dbs]
                           ,direction=_Direction
                           }=LVPs) ->
    Limit = limit_by_page_size(Context, PageSize),

    lager:debug("limit: ~p page_size: ~p dir: ~p", [Limit, PageSize, _Direction]),

    DefaultOptions =
        props:filter_undefined(
          [{'startkey', StartKey}
          ,{'limit', Limit}
           | props:delete_keys(['startkey', 'limit', 'databases'], Options)
          ]),

    IncludeOptions =
        case has_qs_filter(Context) of
            'true' -> ['include_docs' | props:delete('include_docs', DefaultOptions)];
            'false' -> DefaultOptions
        end,

    ViewOptions =
        case props:get_first_defined(['reduce', 'group', 'group_level'], IncludeOptions) of
            'undefined' -> IncludeOptions;
            'false' -> IncludeOptions;
            _V -> props:delete('include_docs', IncludeOptions)
        end,

    lager:debug("kz_datamgr:get_results(~p, ~p, ~p)", [Db, View, ViewOptions]),

    case kz_datamgr:get_results(Db, View, ViewOptions) of
        %% There were more dbs, so move to the next one
        {'error', 'not_found'} when Dbs =:= [] ->
            lager:debug("either the db ~s or view ~s was not found", [Db, View]),
            crossbar_util:response_missing_view(Context);
        {'error', 'not_found'} ->
            lager:debug("either the db ~s or view ~s was not found", [Db, View]),
            load_view(LVPs#load_view_params{dbs=Dbs});
        {'error', Error} ->
            handle_datamgr_errors(Error, View, Context);
        {'ok', JObjs} ->
            lager:debug("paginating view '~s' from '~s', starting at '~p'", [View, Db, StartKey]),
            Pagination = case is_integer(Limit) of
                             'true' -> PageSize;
                             'false' -> Limit
                         end,
            handle_datamgr_pagination_success(JObjs
                                             ,Pagination
                                             ,cb_context:api_version(Context)
                                             ,LVPs#load_view_params{dbs=Dbs
                                                                   ,context=cb_context:set_resp_status(Context, 'success')
                                                                   }
                                             )
    end.

-spec limit_by_page_size(api_binary() | pos_integer()) -> api_pos_integer().
-spec limit_by_page_size(cb_context:context(), api_binary() | pos_integer()) -> api_pos_integer().
limit_by_page_size('undefined') -> 'undefined';
limit_by_page_size(N) when is_integer(N) -> N+1;
limit_by_page_size(<<_/binary>> = B) -> limit_by_page_size(kz_util:to_integer(B)).

limit_by_page_size(Context, PageSize) ->
    case cb_context:should_paginate(Context) of
        'true' -> limit_by_page_size(PageSize);
        'false' ->
            lager:debug("pagination disabled in context"),
            'undefined'
    end.

-spec start_key(cb_context:context()) -> kz_json:api_json_term().
-spec start_key(kz_proplist(), cb_context:context()) -> kz_json:api_json_term().
start_key(Context) ->
    cb_context:req_value(Context, <<"start_key">>).

start_key(Options, Context) ->
    case props:get_value('startkey_fun', Options) of
        'undefined' -> start_key_fun(Options, Context);
        Fun when is_function(Fun, 2) -> Fun(Options, Context);
        Fun when is_function(Fun, 1) -> Fun(Context)
    end.

-spec start_key_fun(kz_proplist(), cb_context:context()) -> kz_json:api_json_term().
start_key_fun(Options, Context) ->
    case props:get_value('startkey', Options) of
        'undefined' ->
            StartKey = start_key(Context),
            lager:debug("got start_key from request: ~p", [StartKey]),
            StartKey;
        StartKey ->
            lager:debug("getting start_key from options: ~p", [StartKey]),
            StartKey
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to load the context with the results of all the
%% docs in the supplied Db, with the fold function weeding out those not
%% desired by returning 'undefined' or not adding it to the Accumulator
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec load_docs(cb_context:context(), filter_fun()) -> cb_context:context().
load_docs(Context, Filter)
  when is_function(Filter, 2);
       is_function(Filter, 3) ->
    Fun = case is_function(Filter, 2) of
              'true' -> Filter;
              'false' -> fun(J, Acc) -> Filter(Context, J, Acc) end
          end,
    case kz_datamgr:all_docs(cb_context:account_db(Context)) of
        {'error', Error} -> handle_datamgr_errors(Error, <<"all_docs">>, Context);
        {'ok', JObjs} ->
            Filtered = [JObj
                        || JObj <- lists:foldl(Fun, [], JObjs)
                               ,(not kz_util:is_empty(JObj))
                       ],
            handle_datamgr_success(Filtered, Context)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to load the context with the binary payload
%% stored as an attachment
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec load_attachment({ne_binary(), ne_binary()} | kazoo_data:docid() | kz_json:object(), ne_binary(), kz_proplist(), cb_context:context()) ->
                             cb_context:context().
load_attachment({DocType, DocId}, AName, Options, Context) ->
    load_attachment(DocId, AName, [{'doc_type', DocType} | Options], Context);
load_attachment(<<_/binary>>=DocId, AName, Options, Context) ->
    case kz_datamgr:fetch_attachment(cb_context:account_db(Context), DocId, AName, Options) of
        {'error', Error} -> handle_datamgr_errors(Error, DocId, Context);
        {'ok', AttachBin} ->
            lager:debug("loaded attachment ~s from doc ~s from db ~s"
                       ,[AName, DocId, cb_context:account_db(Context)]
                       ),
            Context1 = load(DocId, Context, Options),
            'success' = cb_context:resp_status(Context1),
            cb_context:setters(Context1
                              ,[{fun cb_context:set_resp_data/2, AttachBin}
                               ,{fun cb_context:set_resp_etag/2, rev_to_etag(cb_context:doc(Context1))}
                               ])
    end;
load_attachment(Doc, AName, Options, Context) ->
    load_attachment({kz_doc:type(Doc), kz_doc:id(Doc)}, AName, Options, Context).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to save the provided document to the accounts
%% database. The result is loaded into the context record.
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec save(cb_context:context()) ->
                  cb_context:context().
-spec save(cb_context:context(), kz_proplist()) ->
                  cb_context:context().
-spec save(cb_context:context(), kz_json:object() | kz_json:objects(), kz_proplist()) ->
                  cb_context:context().

save(Context) ->
    save(Context, []).
save(Context, Options) ->
    save(Context, cb_context:doc(Context), Options).

save(Context, [], _Options) ->
    lager:debug("no docs to save"),
    cb_context:set_resp_status(Context, 'success');
save(Context, [_|_]=JObjs, Options) ->
    JObjs0 = update_pvt_parameters(JObjs, Context),
    case kz_datamgr:save_docs(cb_context:account_db(Context), JObjs0, Options) of
        {'error', Error} ->
            IDs = [kz_doc:id(JObj) || JObj <- JObjs],
            handle_datamgr_errors(Error, IDs, Context);
        {'ok', JObj1} ->
            Context1 = handle_datamgr_success(JObj1, Context),
            _ = kz_util:spawn(fun provisioner_util:maybe_send_contact_list/1, [Context1]),
            Context1
    end;
save(Context, JObj, Options) ->
    JObj0 = update_pvt_parameters(JObj, Context),
    case kz_datamgr:save_doc(cb_context:account_db(Context), JObj0, Options) of
        {'error', Error} ->
            DocId = kz_doc:id(JObj0),
            handle_datamgr_errors(Error, DocId, Context);
        {'ok', JObj1} ->
            Context1 = handle_datamgr_success(JObj1, Context),
            _ = kz_util:spawn(fun provisioner_util:maybe_send_contact_list/1, [Context1]),
            Context1
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function attempts to save the provided document to the accounts
%% database. The result is loaded into the context record.
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec ensure_saved(cb_context:context()) ->
                          cb_context:context().
-spec ensure_saved(cb_context:context(), kz_proplist()) ->
                          cb_context:context().
-spec ensure_saved(cb_context:context(), kz_json:object() | kz_json:objects(), kz_proplist()) ->
                          cb_context:context().

ensure_saved(Context) ->
    ensure_saved(Context, []).

ensure_saved(Context, Options) ->
    ensure_saved(Context, cb_context:doc(Context), Options).

ensure_saved(Context, JObj, Options) ->
    JObj0 = update_pvt_parameters(JObj, Context),
    case kz_datamgr:ensure_saved(cb_context:account_db(Context), JObj0, Options) of
        {'error', Error} ->
            DocId = kz_doc:id(JObj0),
            handle_datamgr_errors(Error, DocId, Context);
        {'ok', JObj1} ->
            Context1 = handle_datamgr_success(JObj1, Context),
            _ = kz_util:spawn(fun provisioner_util:maybe_send_contact_list/1, [Context1]),
            Context1
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Save the Contents as an attachment on the document.
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec save_attachment(ne_binary(), ne_binary(), ne_binary(), cb_context:context()) -> cb_context:context().
save_attachment(DocId, AName, Contents, Context) ->
    save_attachment(DocId, AName, Contents, Context, []).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Save the Contents as an attachment on the document with options
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec save_attachment(ne_binary(), ne_binary(), ne_binary(), cb_context:context(), kz_proplist()) ->
                             cb_context:context().
save_attachment(DocId, Name, Contents, Context, Options) ->
    Opts1 = case props:get_value('rev', Options) of
                'undefined' ->
                    {'ok', Rev} = kz_datamgr:lookup_doc_rev(cb_context:account_db(Context), DocId),
                    lager:debug("looking up rev for ~s: ~s", [DocId, Rev]),
                    [{'rev', Rev} | Options];
                _O -> Options
            end,

    AName = kz_util:clean_binary(Name),

    case kz_datamgr:put_attachment(cb_context:account_db(Context), DocId, AName, Contents, Opts1) of
        {'error', 'conflict'=Error} ->
            lager:debug("saving attachment resulted in a conflict, checking for validity"),
            Context1 = load(DocId, Context, [{'use_cache', 'false'} | Options]),
            case kz_doc:attachment(cb_context:doc(Context1), AName) of
                'undefined' ->
                    lager:debug("attachment does appear to be missing, reporting error"),
                    _ = maybe_delete_doc(Context, DocId),
                    handle_datamgr_errors(Error, AName, Context);
                _Attachment ->
                    lager:debug("attachment ~s was in _attachments, considering it successful", [AName]),
                    {'ok', Rev1} = kz_datamgr:lookup_doc_rev(cb_context:account_db(Context), DocId),
                    cb_context:setters(Context
                                      ,[{fun cb_context:set_doc/2, kz_json:new()}
                                       ,{fun cb_context:set_resp_status/2, 'success'}
                                       ,{fun cb_context:set_resp_data/2, kz_json:new()}
                                       ,{fun cb_context:set_resp_etag/2, rev_to_etag(Rev1)}
                                       ])
            end;
        {'error', Error} ->
            lager:debug("error putting attachment into ~s: ~p"
                       ,[cb_context:account_db(Context), Error]
                       ),
            _ = maybe_delete_doc(Context, DocId),
            handle_datamgr_errors(Error, AName, Context);
        {'ok', _Res} ->
            lager:debug("saved attachment ~s to doc ~s to db ~s"
                       ,[AName, DocId, cb_context:account_db(Context)]
                       ),
            {'ok', Rev1} = kz_datamgr:lookup_doc_rev(cb_context:account_db(Context), DocId),
            cb_context:setters(Context
                              ,[{fun cb_context:set_doc/2, kz_json:new()}
                               ,{fun cb_context:set_resp_status/2, 'success'}
                               ,{fun cb_context:set_resp_data/2, kz_json:new()}
                               ,{fun cb_context:set_resp_etag/2, rev_to_etag(Rev1)}
                               ])
    end.

-spec maybe_delete_doc(cb_context:context(), ne_binary()) ->
                              {'ok', _} |
                              {'error', any()}.
maybe_delete_doc(Context, DocId) ->
    AccountDb = cb_context:account_db(Context),
    case kz_datamgr:open_doc(AccountDb, DocId) of
        {'error', _}=Error -> Error;
        {'ok', JObj} ->
            case kz_doc:attachments(JObj) of
                'undefined' -> kz_datamgr:del_doc(AccountDb, JObj);
                _Attachments -> {'ok', 'non_empty'}
            end
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will attempt to remove an account document from the
%% account database.  This is preformed as a soft-delete and enforced
%% by the views.  Clean up process remove old data based on the delete
%% flag and last modified date
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec delete(cb_context:context()) -> cb_context:context().
-spec delete(cb_context:context(), 'permanent' | 'soft') -> cb_context:context().

delete(Context) ->
    delete(Context, 'soft').

delete(Context, 'soft') ->
    Doc = cb_context:doc(Context),
    case kz_datamgr:lookup_doc_rev(cb_context:account_db(Context), kz_doc:id(Doc)) of
        {'ok', Rev}   -> soft_delete(Context, Rev);
        {'error', _E} -> soft_delete(Context, kz_doc:revision(Doc))
    end;
delete(Context, 'permanent') ->
    do_delete(Context, cb_context:doc(Context), fun kz_datamgr:del_doc/2).

-spec soft_delete(cb_context:context(), api_binary()) -> cb_context:context().
soft_delete(Context, Rev) ->
    lager:debug("soft deleting with rev ~s", [Rev]),
    JObj1 = lists:foldl(fun({F, V}, J) -> F(J, V) end
                       ,update_pvt_parameters(cb_context:doc(Context), Context)
                       ,[{fun kz_doc:set_soft_deleted/2, 'true'}
                        ,{fun kz_doc:set_revision/2, Rev}
                        ]),
    do_delete(Context, JObj1, fun kz_datamgr:save_doc/2).

-type delete_fun() :: fun((ne_binary(), kz_json:object() | ne_binary()) ->
                                 {'ok', kz_json:object() | kz_json:objects()} |
                                 kz_data:data_error()).

-spec do_delete(cb_context:context(), kz_json:object(), delete_fun()) ->
                       cb_context:context().
do_delete(Context, JObj, CouchFun) ->
    case CouchFun(cb_context:account_db(Context), JObj) of
        {'error', 'not_found'} ->
            lager:debug("doc ~s wasn't found in ~s, not deleting"
                       ,[kz_doc:id(JObj), cb_context:account_db(Context)]
                       ),
            handle_datamgr_success(JObj, Context);
        {'error', Error} ->
            DocId = kz_doc:id(JObj),
            handle_datamgr_errors(Error, DocId, Context);
        {'ok', _} ->
            lager:debug("'deleted' ~s from ~s using ~p"
                       ,[kz_doc:id(JObj), cb_context:account_db(Context), CouchFun]
                       ),
            Context1 = handle_datamgr_success(JObj, Context),
            _ = kz_util:spawn(fun provisioner_util:maybe_send_contact_list/1, [Context1]),
            Context1
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will attempt to remove an attachment from a document.
%% Unlike the delete function, this is NOT a soft-delete.
%%
%% Failure here returns 500 or 503
%% @end
%%--------------------------------------------------------------------
-spec delete_attachment(ne_binary(), ne_binary(), cb_context:context()) ->
                               cb_context:context().
delete_attachment(DocId, AName, Context) ->
    case kz_datamgr:delete_attachment(cb_context:account_db(Context), DocId, AName) of
        {'error', 'not_found'} -> handle_datamgr_success(kz_json:new(), Context);
        {'error', Error} ->
            lager:debug("failed to delete attachment: ~p", [Error]),
            handle_datamgr_errors(Error, AName, Context);
        {'ok', _} ->
            lager:debug("deleted attachment ~s from doc ~s from ~s"
                       ,[AName, DocId, cb_context:account_db(Context)]
                       ),
            handle_datamgr_success(kz_json:new(), Context)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function will attempt to convert a revision tag on the provided
%% document into a usable ETag for the response
%% @end
%%--------------------------------------------------------------------
-spec rev_to_etag(kz_json:object() | kz_json:objects() | ne_binary()) ->
                         'automatic' | api_string().
rev_to_etag([_|_])-> 'automatic';
rev_to_etag([]) -> 'undefined';
rev_to_etag(Rev) when is_binary(Rev) -> kz_util:to_list(Rev);
rev_to_etag(JObj) ->
    case kz_doc:revision(JObj) of
        'undefined' -> 'undefined';
        Rev -> kz_util:to_list(Rev)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_pagination_envelope_params(cb_context:context(), any(), api_non_neg_integer()) ->
                                               cb_context:context().
update_pagination_envelope_params(Context, StartKey, PageSize) ->
    update_pagination_envelope_params(Context
                                     ,StartKey
                                     ,PageSize
                                     ,'undefined'
                                     ,cb_context:should_paginate(Context)
                                     ).

-spec update_pagination_envelope_params(cb_context:context(), any(), api_non_neg_integer(), api_binary()) ->
                                               cb_context:context().
update_pagination_envelope_params(Context, StartKey, PageSize, NextStartKey) ->
    update_pagination_envelope_params(Context
                                     ,StartKey
                                     ,PageSize
                                     ,NextStartKey
                                     ,cb_context:should_paginate(Context)
                                     ).

-spec update_pagination_envelope_params(cb_context:context(), any(), api_non_neg_integer(), api_binary(), boolean()) ->
                                               cb_context:context().
update_pagination_envelope_params(Context, _StartKey, _PageSize, _NextStartKey, 'false') ->
    lager:debug("pagination disabled, removing resp envelope keys"),
    cb_context:set_resp_envelope(Context
                                ,kz_json:delete_keys([<<"start_key">>
                                                     ,<<"page_size">>
                                                     ,<<"next_start_key">>
                                                     ]
                                                    ,cb_context:resp_envelope(Context)
                                                    )
                                );
update_pagination_envelope_params(Context, StartKey, PageSize, NextStartKey, 'true') ->
    RespEnvelope = cb_context:resp_envelope(Context),
    CurrentPageSize = kz_json:get_integer_value(<<"page_size">>, RespEnvelope, 0),
    cb_context:set_resp_envelope(Context
                                ,kz_json:set_values(props:filter_undefined(
                                                      [{<<"start_key">>, StartKey}
                                                      ,{<<"page_size">>, PageSize + CurrentPageSize}
                                                      ,{<<"next_start_key">>, NextStartKey}
                                                      ])
                                                   ,RespEnvelope
                                                   )
                                ).

-spec handle_datamgr_pagination_success(kz_json:objects(), api_pos_integer(), ne_binary(), load_view_params()) ->
                                               cb_context:context().
handle_datamgr_pagination_success(JObjs
                                 ,_PageSize
                                 ,?VERSION_1
                                 ,#load_view_params{context=Context
                                                   ,filter_fun=FilterFun
                                                   ,direction=Direction
                                                   }=LVPs
                                 ) ->
    load_view(LVPs#load_view_params{
                context=cb_context:set_doc(Context
                                          ,apply_filter(FilterFun, JObjs, Context, Direction)
                                           ++ cb_context:doc(Context)
                                          )
               });

handle_datamgr_pagination_success([]
                                 ,_PageSize
                                 ,_Version
                                 ,#load_view_params{context=Context
                                                   ,start_key=StartKey
                                                   }=LVPs
                                 ) ->
    load_view(LVPs#load_view_params{context=update_pagination_envelope_params(Context, StartKey, 0)});

handle_datamgr_pagination_success([_|_]=JObjs
                                 ,'undefined'
                                 ,_Version
                                 ,#load_view_params{context=Context
                                                   ,start_key=StartKey
                                                   ,filter_fun=FilterFun
                                                   ,page_size=PageSize
                                                   ,direction=Direction
                                                   }=LVPs
                                 ) ->
    Filtered = apply_filter(FilterFun, JObjs, Context, Direction),
    FilteredCount = length(Filtered),

    load_view(LVPs#load_view_params{context=
                                        update_pagination_envelope_params(
                                          cb_context:set_doc(Context, Filtered ++ cb_context:doc(Context))
                                                                         ,StartKey
                                                                         ,FilteredCount
                                         )
                                   ,page_size=PageSize-FilteredCount
                                   });

handle_datamgr_pagination_success([_|_]=JObjs
                                 ,PageSize
                                 ,_Version
                                 ,#load_view_params{context=Context
                                                   ,start_key=StartKey
                                                   ,filter_fun=FilterFun
                                                   ,direction=Direction
                                                   }=LVPs
                                 ) ->
    try lists:split(PageSize, JObjs) of
        {Results, []} ->
            Filtered = apply_filter(FilterFun, Results, Context, Direction),

            load_view(LVPs#load_view_params{
                        context=
                            cb_context:set_doc(
                              update_pagination_envelope_params(Context, StartKey, PageSize)
                                              ,Filtered ++ cb_context:doc(Context)
                             )
                                           ,page_size=0
                       });
        {Results, [NextJObj]} ->
            NextStartKey = kz_json:get_value(<<"key">>, NextJObj),
            Filtered = apply_filter(FilterFun, Results, Context, Direction),
            lager:debug("next start key: ~p", [NextStartKey]),

            load_view(LVPs#load_view_params{
                        context=
                            cb_context:set_doc(
                              update_pagination_envelope_params(Context, StartKey, PageSize, NextStartKey)
                                              ,Filtered ++ cb_context:doc(Context)
                             )
                                           ,page_size=0
                       })
    catch
        'error':'badarg' ->
            Filtered = apply_filter(FilterFun, JObjs, Context, Direction),
            FilteredCount = length(Filtered),

            lager:debug("recv less than ~p results: ~p", [PageSize, FilteredCount]),

            load_view(LVPs#load_view_params{
                        context=
                            cb_context:set_doc(
                              update_pagination_envelope_params(Context, StartKey, FilteredCount)
                                              ,Filtered ++ cb_context:doc(Context)
                             )
                                           ,page_size=PageSize - FilteredCount
                       })
    end.

-type filter_fun() :: fun((kz_json:object(), kz_json:objects()) -> kz_json:objects()) |
                      fun((cb_context:context(), kz_json:object(), kz_json:objects()) -> kz_json:objects()).

-spec apply_filter('undefined' | filter_fun(), kz_json:objects(), cb_context:context(), direction()) ->
                          kz_json:objects().
-spec apply_filter('undefined' | filter_fun(), kz_json:objects(), cb_context:context(), direction(), boolean()) ->
                          kz_json:objects().
apply_filter(FilterFun, JObjs, Context, Direction) ->
    apply_filter(FilterFun, JObjs, Context, Direction, has_qs_filter(Context)).

apply_filter(FilterFun, JObjs, Context, Direction, HasQSFilter) ->
    lager:debug("applying filter fun: ~p, qs filter: ~p to dir ~p", [FilterFun, HasQSFilter, Direction]),

    Filtered =
        maybe_apply_custom_filter(Context
                                 ,FilterFun
                                 ,[JObj
                                   || JObj <- JObjs,
                                      filtered_doc_by_qs(JObj, HasQSFilter, Context)
                                  ]),
    lager:debug("filter resulted in ~p out of ~p objects"
               ,[length(Filtered), length(JObjs)]),
    case Direction of
        'ascending' -> Filtered;
        'descending' -> lists:reverse(Filtered)
    end.

-spec maybe_apply_custom_filter(cb_context:context(), 'undefined' | filter_fun(), kz_json:objects()) -> kz_json:objects().
maybe_apply_custom_filter(_Context, 'undefined', JObjs) -> JObjs;
maybe_apply_custom_filter(Context, FilterFun, JObjs) ->
    Fun = case is_function(FilterFun, 2) of
              'true' -> FilterFun;
              'false' -> fun(J, Acc) -> FilterFun(Context, J, Acc) end
          end,
    [JObj
     || JObj <- lists:foldl(Fun, [], JObjs),
        not kz_util:is_empty(JObj)
    ].

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec filtered_doc_by_qs(kz_json:object(), cb_context:context()) -> boolean().
-spec filtered_doc_by_qs(kz_json:object(), boolean(), cb_context:context()) -> boolean().

filtered_doc_by_qs(JObj, Context) ->
    filter_doc(JObj, Context).

filtered_doc_by_qs(_JObj, 'false', _Context) -> 'true';
filtered_doc_by_qs(JObj, 'true', Context) ->
    filter_doc(kz_json:get_value(<<"doc">>, JObj), Context).

-spec handle_datamgr_success(kz_json:object() | kz_json:objects(), cb_context:context()) -> cb_context:context().
handle_datamgr_success([], Context) ->
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, []}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, []}
                       ,{fun cb_context:set_resp_etag/2, 'undefined'}
                        | version_specific_success([], Context)
                       ]);
handle_datamgr_success([JObj|_]=JObjs, Context) ->
    case kz_json:is_json_object(JObj) of
        'true' -> handle_json_success(JObjs, Context);
        'false' -> handle_thing_success(JObjs, Context)
    end;
handle_datamgr_success(JObj, Context) ->
    case kz_json:is_json_object(JObj) of
        'true' -> handle_json_success(JObj, Context);
        'false' -> handle_thing_success(JObj, Context)
    end.

%% FIXME: not used
-spec handle_thing_success(any(), cb_context:context()) -> cb_context:context().
handle_thing_success(Thing, Context) ->
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, Thing}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, Thing}
                       ,{fun cb_context:set_resp_etag/2, 'undefined'}
                       ]).

-spec handle_json_success(kz_json:object() | kz_json:objects(), cb_context:context()) ->
                                 cb_context:context().
-spec handle_json_success(kz_json:object() | kz_json:objects(), cb_context:context(), http_method()) ->
                                 cb_context:context().
handle_json_success(JObj, Context) ->
    handle_json_success(JObj, Context, cb_context:req_verb(Context)).

handle_json_success([_|_]=JObjs, Context, ?HTTP_PUT) ->
    RespData = [kz_json:public_fields(JObj)
                || JObj <- JObjs,
                   not kz_doc:is_soft_deleted(JObj)
               ],
    RespHeaders = [{<<"Location">>, kz_doc:id(JObj)}
                   || JObj <- JObjs
                  ] ++ cb_context:resp_headers(Context),
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, JObjs}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, RespData}
                       ,{fun cb_context:set_resp_etag/2, rev_to_etag(JObjs)}
                       ,{fun cb_context:set_resp_headers/2, RespHeaders}
                       ]);
handle_json_success([_|_]=JObjs, Context, _Verb) ->
    RespData = [kz_json:public_fields(JObj)
                || JObj <- JObjs,
                   not kz_doc:is_soft_deleted(JObj)
               ],
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, JObjs}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, RespData}
                       ,{fun cb_context:set_resp_etag/2, rev_to_etag(JObjs)}
                        | version_specific_success(JObjs, Context)
                       ]);
handle_json_success(JObj, Context, ?HTTP_PUT) ->
    RespHeaders = [{<<"Location">>, kz_doc:id(JObj)}
                   | cb_context:resp_headers(Context)
                  ],
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, JObj}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, kz_json:public_fields(JObj)}
                       ,{fun cb_context:set_resp_etag/2, rev_to_etag(JObj)}
                       ,{fun cb_context:set_resp_headers/2, RespHeaders}
                       ]);
handle_json_success(JObj, Context, _Verb) ->
    cb_context:setters(Context
                      ,[{fun cb_context:set_doc/2, JObj}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ,{fun cb_context:set_resp_data/2, kz_json:public_fields(JObj)}
                       ,{fun cb_context:set_resp_etag/2, rev_to_etag(JObj)}
                       ]).

-spec version_specific_success(kz_json:objects(), cb_context:context()) -> list().
version_specific_success(JObjs, Context) ->
    version_specific_success(JObjs, Context, cb_context:api_version(Context)).
version_specific_success(_JObjs, _Context, ?VERSION_1) ->
    [];
version_specific_success(JObjs, Context, _Version) ->
    [{fun cb_context:set_resp_envelope/2
     ,kz_json:set_value(<<"page_size">>, length(JObjs), cb_context:resp_envelope(Context))
     }
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_datamgr_errors(kazoo_data:data_errors(), api_binary() | api_binaries(), cb_context:context()) ->
                                   cb_context:context().
handle_datamgr_errors('invalid_db_name', _, Context) ->
    lager:debug("datastore ~s not_found", [cb_context:account_db(Context)]),
    cb_context:add_system_error('datastore_missing', kz_json:from_list([{<<"cause">>, cb_context:account_db(Context)}]), Context);
handle_datamgr_errors('db_not_reachable', _DocId, Context) ->
    lager:debug("operation on doc ~s from ~s failed: db_not_reachable", [_DocId, cb_context:account_db(Context)]),
    cb_context:add_system_error('datastore_unreachable', Context);
handle_datamgr_errors('not_found', DocId, Context) ->
    lager:debug("operation on doc ~s from ~s failed: not_found", [DocId, cb_context:account_db(Context)]),
    cb_context:add_system_error('bad_identifier', kz_json:from_list([{<<"cause">>, DocId}]),  Context);
handle_datamgr_errors('conflict', DocId, Context) ->
    lager:debug("failed to update doc ~s in ~s: conflicts", [DocId, cb_context:account_db(Context)]),
    cb_context:add_system_error('datastore_conflict', Context);
handle_datamgr_errors('invalid_view_name', View, Context) ->
    lager:debug("loading view ~s from ~s failed: invalid view", [View, cb_context:account_db(Context)]),
    cb_context:add_system_error('datastore_missing_view', kz_json:from_list([{<<"cause">>, kz_util:to_binary(View)}]), Context);
handle_datamgr_errors(Else, _View, Context) ->
    lager:debug("operation failed: ~p on ~p", [Else, _View]),
    try kz_util:to_binary(Else) of
        Reason -> cb_context:add_system_error('datastore_fault', kz_json:from_list([{<<"cause">>, Reason}]), Context)
    catch
        _:_ -> cb_context:add_system_error('datastore_fault', Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is used to update the private timestamps, and db
%% parameters on all crossbar documents
%% @end
%%--------------------------------------------------------------------
-spec update_pvt_parameters(kz_json:object() | kz_json:objects(), cb_context:context()) ->
                                   kz_json:object() | kz_json:objects().
update_pvt_parameters(JObjs, Context) when is_list(JObjs) ->
    [update_pvt_parameters(JObj, Context) || JObj <- JObjs];
update_pvt_parameters(JObj0, Context) ->
    lists:foldl(fun(Fun, JObj) ->
                        apply_pvt_fun(Fun, JObj, Context)
                end
               ,JObj0
               ,?PVT_FUNS
               ).

-type pvt_fun() :: fun((kz_json:object(), cb_context:context()) -> kz_json:object()).
-spec apply_pvt_fun(pvt_fun(), kz_json:object(), cb_context:context()) ->
                           kz_json:object().
apply_pvt_fun(Fun, JObj, Context) ->
    Fun(JObj, Context).

-spec add_pvt_vsn(kz_json:object(), cb_context:context()) -> kz_json:object().
add_pvt_vsn(JObj, _) ->
    case kz_doc:vsn(JObj) of
        'undefined' -> kz_doc:set_vsn(JObj, ?CROSSBAR_DOC_VSN);
        _ -> JObj
    end.

-spec add_pvt_account_db(kz_json:object(), cb_context:context()) -> kz_json:object().
add_pvt_account_db(JObj, Context) ->
    case kz_doc:account_db(JObj) of
        'undefined' ->
            case cb_context:account_db(Context) of
                'undefined' -> JObj;
                AccountDb -> kz_doc:set_account_db(JObj, AccountDb)
            end;
        _Else -> JObj
    end.

-spec add_pvt_account_id(kz_json:object(), cb_context:context()) -> kz_json:object().
add_pvt_account_id(JObj, Context) ->
    case kz_doc:account_id(JObj) of
        'undefined' ->
            case cb_context:account_id(Context) of
                'undefined' -> JObj;
                AccountId -> kz_doc:set_account_id(JObj, AccountId)
            end;
        _Else -> JObj
    end.

-spec add_pvt_created(kz_json:object(), cb_context:context()) -> kz_json:object().
add_pvt_created(JObj, _) ->
    case kz_doc:revision(JObj) of
        'undefined' ->
            Timestamp = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
            kz_doc:set_created(JObj, Timestamp);
        _ ->
            JObj
    end.

-spec add_pvt_modified(kz_json:object(), cb_context:context()) ->
                              kz_json:object().
add_pvt_modified(JObj, _) ->
    Timestamp = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
    kz_doc:set_modified(JObj, Timestamp).

-spec add_pvt_request_id(kz_json:object(), cb_context:context()) ->
                                kz_json:object().
add_pvt_request_id(JObj, Context) ->
    RequestId = cb_context:req_id(Context),
    kz_json:set_value(<<"pvt_request_id">>, RequestId, JObj).

-spec add_pvt_auth(kz_json:object(), cb_context:context()) ->
                          kz_json:object().
add_pvt_auth(JObj, Context) ->
    case cb_context:is_authenticated(Context) of
        'false' -> kz_json:set_value(<<"pvt_is_authenticated">>, 'false', JObj);
        'true' ->
            Values = props:filter_undefined(
                       [{<<"pvt_is_authenticated">>, 'true'}
                       ,{<<"pvt_auth_account_id">>, cb_context:auth_account_id(Context)}
                       ,{<<"pvt_auth_user_id">>, cb_context:auth_user_id(Context)}
                       ]),
            kz_json:set_values(Values, JObj)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec extract_included_docs(kz_json:objects()) -> kz_json:objects().
extract_included_docs(JObjs) ->
    [kz_json:get_value(<<"doc">>, JObj) || JObj <- JObjs].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given a context or query parameter json object determines if the
%% request has a filter defined
%% @end
%%--------------------------------------------------------------------
-spec has_qs_filter(cb_context:context()) -> boolean().
has_qs_filter(Context) ->
    kz_json:any(fun is_filter_key/1
               ,cb_context:query_string(Context)
               ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Given a proplist element from the query string, determines if it
%% represents a filter parameter
%% @end
%%--------------------------------------------------------------------
-spec is_filter_key({binary(), any()}) -> boolean().
is_filter_key({<<"filter_", _/binary>>, _}) -> 'true';
is_filter_key({<<"has_key", _/binary>>, _}) -> 'true';
is_filter_key({<<"key_missing", _/binary>>, _}) -> 'true';
is_filter_key({<<"has_value", _/binary>>, _}) -> 'true';
is_filter_key({<<"created_from">>, _}) -> 'true';
is_filter_key({<<"created_to">>, _}) -> 'true';
is_filter_key({<<"modified_from">>, _}) -> 'true';
is_filter_key({<<"modified_to">>, _}) -> 'true';
is_filter_key(_) -> 'false'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns 'true' if all of the requested props are found, 'false' if one is not found
%% @end
%%--------------------------------------------------------------------
-spec filter_doc(api_object(), cb_context:context()) -> boolean().
filter_doc('undefined', _Context) ->
    lager:debug("no doc was returned (no include_docs?)"),
    'true';
filter_doc(Doc, Context) ->
    filter_doc_by_querystring(Doc, cb_context:query_string(Context)).

-spec filter_doc_by_querystring(kz_json:object(), kz_json:object()) -> boolean().
filter_doc_by_querystring(Doc, QueryString) ->
    kz_json:all(fun({K, V}) ->
                        should_filter_doc(Doc, K, V)
                end
               ,QueryString
               ).

-spec should_filter_doc(kz_json:object(), ne_binary(), kz_json:json_term()) -> boolean().
should_filter_doc(Doc, K, V) ->
    try filter_prop(Doc, K, V) of
        'undefined' -> 'true';
        Bool -> Bool
    catch
        _E:_R ->
            lager:debug("failed to process filter ~s: ~s:~p", [K, _E, _R]),
            'false'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns 'true' or 'false' if the prop is found inside the doc
%% @end
%%--------------------------------------------------------------------
-spec filter_prop(kz_json:object(), ne_binary(), any()) -> api_boolean().
filter_prop(Doc, <<"filter_not_", Key/binary>>, Val) ->
    not should_filter(Doc, Key, Val);
filter_prop(Doc, <<"filter_", Key/binary>>, Val) ->
    should_filter(Doc, Key, Val);
filter_prop(Doc, <<"has_key">>, Key) ->
    has_key(Doc, Key);
filter_prop(Doc, <<"key_missing">>, Key) ->
    not has_key(Doc, Key);
filter_prop(Doc, <<"has_value">>, Key) ->
    has_value(Doc, Key);
filter_prop(Doc, <<"created_from">>, Val) ->
    lowerbound(kz_doc:created(Doc), kz_util:to_integer(Val));
filter_prop(Doc, <<"created_to">>, Val) ->
    upperbound(kz_doc:created(Doc), kz_util:to_integer(Val));
filter_prop(Doc, <<"modified_from">>, Val) ->
    lowerbound(kz_doc:modified(Doc), kz_util:to_integer(Val));
filter_prop(Doc, <<"modified_to">>, Val) ->
    upperbound(kz_doc:modified(Doc), kz_util:to_integer(Val));
filter_prop(_, _, _) ->
    'undefined'.

-spec upperbound(integer(), integer()) -> boolean().
upperbound(DocTimestamp, QSTimestamp) ->
    QSTimestamp >= DocTimestamp.

-spec lowerbound(integer(), integer()) -> boolean().
lowerbound(DocTimestamp, QSTimestamp) ->
    QSTimestamp =< DocTimestamp.

-spec should_filter(binary(), ne_binary()) -> boolean().
-spec should_filter(kz_json:object(), ne_binary(), kz_json:json_term()) -> boolean().
should_filter(Val, Val) -> 'true';
should_filter(Val, FilterVal) ->
    try kz_json:unsafe_decode(FilterVal) of
        List when is_list(List) ->
            lists:member(Val, List);
        _Data ->
            lager:debug("data is not a list: ~p", [_Data]),
            'false'
    catch
        _Error -> 'false'
    end.

should_filter(Doc, Key, Val) ->
    Keys = binary_key_to_json_key(Key),
    should_filter(
      kz_json:get_binary_value(Keys, Doc, <<>>)
                 ,kz_util:to_binary(Val)
     ).

-spec has_key(kz_json:object(), ne_binary()) -> boolean().
has_key(Doc, Key) ->
    Keys = binary_key_to_json_key(Key),
    kz_json:get_value(Keys, Doc) =/= 'undefined'.

-spec has_value(kz_json:object(), ne_binary()) -> boolean().
has_value(Doc, Key) ->
    Keys = binary_key_to_json_key(Key),
    kz_json:get_ne_value(Keys, Doc) =/= 'undefined'.

-spec binary_key_to_json_key(ne_binary()) -> ne_binaries().
binary_key_to_json_key(Key) ->
    binary:split(Key, <<".">>, ['global']).
