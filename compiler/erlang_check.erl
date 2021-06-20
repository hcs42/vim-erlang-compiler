#!/usr/bin/env escript
%%! -hidden

%%% This script performs syntax check on the given files, and optionally
%%% compiles them.
%%%
%%% See more information in the {@link print_help/0} function.

% 'compile' mode gives better error messages if the script throws an error.
-mode(compile).

%%%=============================================================================
%%% Types
%%%=============================================================================

-type build_system() :: rebar | rebar3 | makefile.

%%%=============================================================================
%%% Main function
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc This function is the entry point of the script.
%%
%% Iterate over the given files, print their compilation warnings and errors,
%% and exit with an appropriate exit code.
%% @end
%%------------------------------------------------------------------------------
-spec main(Args) -> no_return() when
      Args :: [string()].
main([]) ->
    io:format("Usage: see --help.~n"),
    halt(2);
main(Args) ->
    Files = parse_args(Args),

    case get(outdir) of
        undefined ->
            % xref, load and copy is supported only if outdir is also specified
            disable(xref),
            disable(load),
            disable(copy);
        _ ->
            ok
    end,

    case [File || File <- Files, check_file(File) /= ok ] of
        % No Errors (but there could be Warnings!)
        [] ->
            halt(0);
        % At least one Error
        _Errors ->
            halt(1)
    end.

%%%=============================================================================
%%% Parse command line arguments
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Parse the argument list.
%%
%% Put the options into the process dictionary and return the list of files.
%% @end
%%------------------------------------------------------------------------------
-spec parse_args(Args) -> FileNames when
      Args :: [string()],
      FileNames :: [string()].
parse_args(Args) ->
    lists:reverse(parse_args(Args, [])).

%%------------------------------------------------------------------------------
%% @doc Parse the argument list.
%%
%% Put the options into the process dictionary and return the list of files in
%% reverse order.
%% @end
%%------------------------------------------------------------------------------
-spec parse_args(Args, FileNames) -> FileNames when
      Args :: [string()],
      FileNames :: [string()].
parse_args([], Acc) ->
    Acc;
parse_args([Help|_], _Acc) when Help == "-h";
                                Help == "--help" ->
    print_help(),
    halt(0);
parse_args([Verbose|OtherArgs], Acc) when Verbose == "-v";
                                          Verbose == "--verbose" ->
    put(verbose, true),
    log("Verbose mode on.~n"),
    parse_args(OtherArgs, Acc);
parse_args(["--outdir", OutDir|OtherArgs], Acc) ->
    put(outdir, OutDir),
    parse_args(OtherArgs, Acc);
parse_args(["--outdir"], _Acc) ->
    log_error("Argument needed after '--outdir'.~n"),
    halt(2);
parse_args(["--nooutdir"|OtherArgs], Acc) ->
    erase(outdir),
    parse_args(OtherArgs, Acc);
parse_args(["--xref"|OtherArgs], Acc) ->
    put(xref, true),
    parse_args(OtherArgs, Acc);
parse_args(["--load", LongOrShortNames|_OtherArgs], _Acc)
  when LongOrShortNames =/= "shortnames",
       LongOrShortNames =/= "longnames" ->
    log_error("First argument after '--load' should be shortnames or "
              "longnames.~n"),
    halt(2);
parse_args(["--load", LongOrShortNames, MyNodeName, TargetNodeName|OtherArgs],
           Acc) ->
    put(load, {list_to_atom(LongOrShortNames),
               list_to_atom(MyNodeName),
               list_to_atom(TargetNodeName)}),
    parse_args(OtherArgs, Acc);
parse_args(["--load"|_], _Acc) ->
    log_error("More arguments needed after '--load'.~n"),
    halt(2);
parse_args(["--cookie", Cookie|OtherArgs], Acc) ->
    put(cookie, list_to_atom(Cookie)),
    parse_args(OtherArgs, Acc);
parse_args(["--cookie"], _Acc) ->
    log_error("Argument needed after '--cookie'.~n"),
    halt(2);
parse_args(["--copy", TargetDir|OtherArgs], Acc) ->
    put(copy, TargetDir),
    parse_args(OtherArgs, Acc);
parse_args(["--copy"], _Acc) ->
    log_error("Argument needed after '--copy'.~n"),
    halt(2);
parse_args(["--"|Files], Acc) ->
    Files ++ Acc;
parse_args([[$-|_] = Arg|_], _Acc) ->
    log_error("Unknown option: ~s~n", [Arg]),
    halt(2);
parse_args([File|OtherArgs], Acc) ->
    parse_args(OtherArgs, [File|Acc]).

%%------------------------------------------------------------------------------
%% @doc Print the script's help text.
%% @end
%%------------------------------------------------------------------------------
-spec print_help() -> ok.
print_help() ->
    Text =
"Usage: erlang_check.erl [options] [--] <files>

Description:
  erlang_check.erl performs syntax check on the given files, and optionally
  (with the --outdir option) compiles them.

Options:
  --            Process all remaining parameters as filenames.
  -h, --help    Print help.
  -v, --verbose Verbose output.
  --outdir DIR  Put the compiled beam file into the given directory. It is
                relative to directory containing the file to compile.
  --nooutdir    Don't create beam file (default).
  --xref        Execute xref on the beam file and print undefined functions.
                (Other xref warnings are not printed, because those should be
                also printed by the compiler.) Works only if --outdir is
                specified.
  --load NODE_NAME_TYPE MY_NODE_NAME TARGET_NODE_NAME
                After successful compilation, start a node with MY_NODE_NAME and
                load the module into the target node. NODE_NAME_TYPE must be
                either 'shortnames' or 'longnames'. Works only if --outdir is
                specified.
  --cookie COOKIE
                When --load is used, this option can be used to set the cookie
                to be used towards the TARGET_NODE_NAME.
  --copy DIR    After successful compilation, all beam files with the same
                number (recursively) under DIR will be overwritten with the
                newly generated beam file. Works only with Erlang R16 and above.
",
    io:format(Text).

%%%=============================================================================
%%% Preparation
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Disable the given feature and print a warning if it was turned on.
%% @end
%%------------------------------------------------------------------------------
-spec disable(Arg) -> ok when
      Arg :: atom().
disable(Arg) ->
    case get(Arg) of
        undefined ->
            ok;
        _ ->
            erase(Arg),
            log_error("Warning: ~p disabled (it requires --outdir).~n", [Arg])
    end.

%%------------------------------------------------------------------------------
%% @doc Try to compile the given file, print the warnings and errors, and return
%% whether there were errors.
%% @end
%%------------------------------------------------------------------------------
-spec check_file(File) -> ok | error when
      File :: string().
check_file(File) ->
    case file_type(File) of
        module ->
            check_module(File);
        escript ->
            check_escript(File);
        {error, Reason} ->
            file_error(File, {file_error, Reason}),
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Return the type of the Erlang source file.
%% @end
%%------------------------------------------------------------------------------
-spec file_type(File) -> Result when
      File :: string(),
      Result :: module | escript | {error, term()}.
file_type(File) ->
    case file:open(File, [raw, read]) of
        {ok, Fd} ->
            Result = read_file_type(Fd),
            ok = file:close(Fd),
            Result;
        {error, _Reason}  = Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% @doc Return the type of the Erlang source file.
%% @end
%%------------------------------------------------------------------------------
-spec read_file_type(FileDescriptor) -> Result when
      FileDescriptor :: file:io_device(),
      Result :: module | escript | {error, term()}.
read_file_type(FileDescriptor) ->
    case file:read(FileDescriptor, 256) of
        {ok, Beginning} ->
            case re:run(Beginning, "^#!.*escript", [{capture, none}]) of
                nomatch ->
                    module;
                match ->
                    escript
            end;
        {error, _Reason} = Error ->
            Error
    end.

%%------------------------------------------------------------------------------
%% @doc Try to compile the given module, print the warnings and errors, and
%% return whether there were errors.
%% @end
%%------------------------------------------------------------------------------
-spec check_module(File) -> ok | error when
      File :: string().
check_module(File) ->
    Dir = filename:dirname(File),
    AbsFile = filename:absname(File),
    AbsDir = filename:absname(Dir),
    put(compiled_file_path, AbsFile),

    {AppRoot, ProjectRoot, BuildSystemOpts} = load_build_info(AbsDir),

    case BuildSystemOpts of
        {opts, Opts} ->
            check_module_2(AbsFile, AbsDir, AppRoot, ProjectRoot, Opts);
        error ->
            error
    end.

%%%=============================================================================
%%% Load build information.
%%%
%%% This code block is also present in erlang_complete.erl in the
%%% vim-erlang-omnicomplete project. If you modify this code block, please also
%%% modify erlang_complete.erl.
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Load information about the build system.
%%
%% The `Path' parameter is the absolute path to the parent directory of the
%% relevant Erlang source file.
%%
%% The code paths are set by the function. The include paths are returned in
%% `BuildSystemOpts'.
%% @end
%%------------------------------------------------------------------------------
-spec load_build_info(Path) -> Result when
      Path :: string(),
      Result :: {AppRoot, ProjectRoot, BuildSystemOpts},
      AppRoot :: string(),
      ProjectRoot :: string(),
      BuildSystemOpts ::  {opts, [{atom(), term()}]} |
                          error.
load_build_info(Path) ->

    % AppRoot: the directory of the Erlang app.
    AppRoot =
        case find_app_root(Path) of
            no_root ->
                log("Could not find project root.~n"),
                Path;
            Root ->
                log("Found project root: ~p~n", [Root]),
                Root
        end,

    {BuildSystem, BuildFiles} = guess_build_system(AppRoot),

    % ProjectRoot: the directory of the Erlang release (if it exists; otherwise
    % same as AppRoot).
    ProjectRoot = get_project_root(BuildSystem, BuildFiles, AppRoot),
    BuildSystemOpts = load_build_files(BuildSystem, ProjectRoot, BuildFiles),

    {AppRoot, ProjectRoot, BuildSystemOpts}.

%%------------------------------------------------------------------------------
%% @doc Traverse the directory structure upwards until is_app_root matches.
%% @end
%%------------------------------------------------------------------------------
-spec find_app_root(Path) -> Root when
      Path :: string(),
      Root :: string() | 'no_root'.
find_app_root("/") ->
    case is_app_root("/") of
        true -> "/";
        false -> no_root
    end;
find_app_root(Path) ->
    case is_app_root(Path) of
        true -> Path;
        false -> find_app_root(filename:dirname(Path))
    end.

%%------------------------------------------------------------------------------
%% @doc Check directory if it is the root of an OTP application.
%% @end
%%------------------------------------------------------------------------------
-spec is_app_root(Path) -> boolean() when
      Path :: string().
is_app_root(Path) ->
    filelib:wildcard("ebin/*.app", Path) /= [] orelse
    filelib:wildcard("src/*.app.src", Path) /= [].

%%------------------------------------------------------------------------------
%% @doc Check for some known files and try to guess what build system is being
%% used.
%% @end
%%------------------------------------------------------------------------------
-spec guess_build_system(Path) -> Result when
      Path :: string(),
      Result :: {build_system(),
                 BuildFiles :: [string()]}.
guess_build_system(Path) ->
    % The order is important, at least Makefile needs to come last since a lot
    % of projects include a Makefile along any other build system.
    BuildSystems = [
                    {rebar3, [
                              "rebar.lock"
                             ]
                    },
                    {rebar, [
                             "rebar.config",
                             "rebar.config.script"
                            ]
                    },
                    {makefile, [
                            "Makefile"
                           ]
                    }
                   ],
    guess_build_system(Path, BuildSystems).

%%------------------------------------------------------------------------------
%% @doc Check which build system's files are contained by the project.
%% @end
%%------------------------------------------------------------------------------
-spec guess_build_system(Path, BuildSystems) -> Result when
      BuildSystems :: [{build_system(),
                        BaseNames :: [string()]}],
      Path :: string(),
      Result :: {build_system(),
                 BuildFiles :: [string()]}.
guess_build_system(_Path, []) ->
    log("Unknown build system.~n"),
    {unknown_build_system, []};
guess_build_system(Path, [{BuildSystem, BaseNames}|Rest]) ->
    log("Try build system: ~p~n", [BuildSystem]),
    case find_files(Path, BaseNames) of
        [] ->
            guess_build_system(Path, Rest);
        BuildFiles ->
            {BuildSystem, BuildFiles}
    end.

%%------------------------------------------------------------------------------
%% @doc Get the root directory of the project.
%% @end
%%------------------------------------------------------------------------------
-spec get_project_root(BuildSystem, BuildFiles, AppRoot) -> ProjectRoot when
      BuildSystem :: build_system(),
      BuildFiles :: [string()],
      AppRoot :: string(),
      ProjectRoot :: string().
get_project_root(rebar3, BuildFiles, _) ->
    RebarLocks = [F || F <- BuildFiles,
                       filename:basename(F) == "rebar.lock"],
    RebarLocksWithPriority = [{F, rebar3_lock_priority(F)} || F <- RebarLocks],
    {RebarLock, _Priority} = hd(lists:keysort(2, RebarLocksWithPriority)),
    filename:dirname(RebarLock);
get_project_root(_BuildSystem, _Files, AppRoot) ->
    AppRoot.

%%------------------------------------------------------------------------------
%% @doc Get the priority of a rebar3 lock file.
%%
%% Standalone rebar3 lock files found along the parent paths could end up making
%% their directories be prioritised in our attempt to search for the true root
%% of the project.
%%
%% This will in turn result in 'rebar.config not found in [...]' kind of errors
%% being printed out when checking for syntax errors.
%%
%% This function attempts to minimise the risk of that happening by prioritising
%% the found locks according to simple heuristics for how likely are those lock
%% files to be the genuine article.
%% @end
%%------------------------------------------------------------------------------
-spec rebar3_lock_priority(Filename) -> Result when
      Filename :: string(),
      Result :: [non_neg_integer()].
rebar3_lock_priority(Filename) ->
    Dir = filename:dirname(Filename),
    AbsDir = filename:absname(Dir),
    {ok, Siblings} = file:list_dir(AbsDir),
    {SiblingDirs, SiblingFiles} =
        lists:partition(fun filelib:is_dir/1, Siblings),
    AbsDirComponents = filename:split(AbsDir),

    MightBeRebarProject = lists:member("rebar.config", SiblingFiles),
    MightBeSingleApp = lists:member("src", SiblingDirs),
    MightBeUmbrellaApp = lists:member("apps", SiblingDirs),
    Depth = length(AbsDirComponents),

    if MightBeRebarProject ->
           % Lock files standing beside a rebar.config file
           % get a higher priority than to those that don't.
           % Between them, those higher in file system hierarchy will
           % themselves get prioritised.
           [1, Depth];
       MightBeSingleApp xor MightBeUmbrellaApp ->
           % Lock files standing beside either a src or apps directory
           % get a higher priority than those that don't.
           % Between them, those higher in file system hierarchy will
           % themselves get prioritised.
           [2, Depth];
       true ->
           % No good criteria remain. Prioritise by placement in
           % file system hierarchy.
           [3, Depth]
    end.

%%------------------------------------------------------------------------------
%% @doc Load the settings from a given set of build system files.
%% @end
%%------------------------------------------------------------------------------
-spec load_build_files(BuildSystem, ProjectRoot, ConfigFiles) -> Result when
      BuildSystem :: build_system(),
      ProjectRoot :: string(),
      ConfigFiles :: [string()],
      Result :: {opts, [{atom(), term()}]} |
                error.
load_build_files(rebar, _ProjectRoot, ConfigFiles) ->
    load_rebar_files(ConfigFiles, no_config);
load_build_files(rebar3, ProjectRoot, _ConfigFiles) ->
    % _ConfigFiles is a list containing only rebar.lock.
    ConfigNames = ["rebar.config", "rebar.config.script"],
    case find_files(ProjectRoot, ConfigNames) of
        [] ->
            log_error("rebar.config not found in ~p~n", [ProjectRoot]),
            error;
        [RebarConfigFile|_] ->
            load_rebar3_files(RebarConfigFile)
    end;
load_build_files(makefile, _ProjectRoot, ConfigFiles) ->
    load_makefiles(ConfigFiles);
load_build_files(unknown_build_system, ProjectRoot, _) ->
    {opts, [
            {i, absname(ProjectRoot, "include")},
            {i, absname(ProjectRoot, "../include")},
            {i, ProjectRoot}
           ]}.

%%------------------------------------------------------------------------------
%% @doc Load the content of each rebar file.
%%
%% Note worthy: The config returned by this function only represents the first
%% rebar file (the one closest to the file to compile). The subsequent rebar
%% files will be processed for code path only.
%% @end
%%------------------------------------------------------------------------------
-spec load_rebar_files(ConfigFiles, Config) -> Result when
      ConfigFiles :: [string()],
      Config :: no_config | [{atom(), term()}],
      Result :: {opts, [{atom(), term()}]} |
                error.
load_rebar_files([], no_config) ->
    error;
load_rebar_files([], Config) ->
    {opts, Config};
load_rebar_files([ConfigFile|Rest], Config) ->
    ConfigPath = filename:dirname(ConfigFile),
    ConfigResult = case filename:extension(ConfigFile) of
                       ".script" -> file:script(ConfigFile);
                       ".config" -> file:consult(ConfigFile)
                   end,
    case ConfigResult of
        {ok, ConfigTerms} ->
            log("rebar.config read: ~s~n", [ConfigFile]),
            NewConfig = process_rebar_config(ConfigPath, ConfigTerms, Config),
            case load_rebar_files(Rest, NewConfig) of
                {opts, SubConfig} -> {opts, SubConfig};
                error -> {opts, NewConfig}
            end;
        {error, Reason} ->
            log_error("rebar.config consult failed:~n"),
            file_error(ConfigFile, {file_error, Reason}),
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Apply a rebar.config file.
%%
%% This function adds the directories in the rebar.config file to the code path
%% and returns and compilation options to be used when compiling the file.
%% @end
%%------------------------------------------------------------------------------
-spec process_rebar_config(Path, Terms, Config) -> Result when
      Path :: string(),
      Terms :: [{atom(), term()}],
      Config :: no_config | [{atom(), term()}],
      Result :: [{atom(), term()}].
process_rebar_config(Path, Terms, Config) ->

    % App layout:
    %
    % * rebar.config
    % * src/
    % * ebin/ => ebin -> code_path
    % * include/ => ".." -> include. This is needed because files in src may
    %                use `-include_lib("appname/include/f.hrl")`

    % Project layout:
    %
    % * rebar.config
    % * src/
    % * $(deps_dir)/
    %   * $(app_name)/
    %     * ebin/ => deps -> code_path
    % * apps/
    %   * $(sub_dir)/
    %     * ebin/ => sub_dirs -> code_path
    %     * include/ => apps -> include

    DepsDir = proplists:get_value(deps_dir, Terms, "deps"),
    LibDirs = proplists:get_value(lib_dirs, Terms, []),
    SubDirs = proplists:get_value(sub_dirs, Terms, []),
    ErlOpts = proplists:get_value(erl_opts, Terms, []),

    % ebin -> code_path (when the rebar.config file is in the app directory
    code:add_pathsa([absname(Path, "ebin")]),

    % deps -> code_path
    code:add_pathsa(filelib:wildcard(absname(Path, DepsDir) ++ "/*/ebin")),

    % libs -> code_path
    code:add_pathsa(filelib:wildcard(absname(Path, LibDirs) ++ "/*/ebin")),

    % sub_dirs -> code_path
    [ code:add_pathsa(filelib:wildcard(absname(Path, SubDir) ++ "/ebin"))
      || SubDir <- SubDirs ],

    case Config of
        no_config ->
            Includes =
            [ {i, absname(Path, Dir)}
              || Dir <- ["apps", "include"] ] ++
            [ {i, absname(Path, filename:append(SubDir, "include"))}
              || SubDir <- SubDirs ],

            Opts = ErlOpts ++ Includes,
            remove_warnings_as_errors(Opts);
        _ ->
            Config
    end.

%%------------------------------------------------------------------------------
%% @doc Load the content of each rebar3 file.
%%
%% Note worthy: The config returned by this function only represent the first
%% rebar file (the one closest to the file to compile).
%% @end
%%------------------------------------------------------------------------------
-spec load_rebar3_files(ConfigFile) -> Result when
      ConfigFile :: string(),
      Result :: {opts, [{atom(), term()}]} |
                error.
load_rebar3_files(ConfigFile) ->
    ConfigPath = filename:dirname(ConfigFile),
    ConfigResult = case filename:extension(ConfigFile) of
                       ".script" -> file:script(ConfigFile);
                       ".config" -> file:consult(ConfigFile)
                   end,
    case ConfigResult of
        {ok, ConfigTerms} ->
            log("rebar.config read: ~s~n", [ConfigFile]),
            try process_rebar3_config(ConfigPath, ConfigTerms) of
                error ->
                    error;
                Config ->
                    {opts, Config}
            catch
                throw:error ->
                    error
            end;
        {error, Reason} ->
            log_error("rebar.config consult failed:~n"),
            file_error(ConfigFile, {file_error, Reason}),
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Apply a rebar.config file.
%%
%% This function adds the directories returned by rebar3 to the code path and
%% returns and compilation options to be used when compiling the file.
%% @end
%%------------------------------------------------------------------------------
-spec process_rebar3_config(ConfigPath, Terms) -> Result when
      ConfigPath :: string(),
      Terms :: [{atom(), term()}],
      Result :: [{atom(), term()}] | error.
process_rebar3_config(ConfigPath, Terms) ->
    case find_rebar3(ConfigPath) of
        not_found ->
            % Compilation would likely fail without settings the paths, so let's
            % give an explicit error instead of proceeding anyway.
            log_error("rebar3 executable not found.~n"),
            error;
        {ok, Rebar3Rel} ->
            log("rebar3 executable found: ~s~n", [Rebar3Rel]),
            Rebar3 = filename:absname(Rebar3Rel),
            log("Absolute path to rebar3 executable: ~s~n", [Rebar3]),
            % load the profile used by rebar3 to print the dependency path list
            Profile = rebar3_get_profile(Terms),
            % "rebar3 path" prints all paths that belong to the project; we add
            % these to the Erlang paths.
            %
            % QUIET=1 ensures that it won't print other messages, see
            % https://github.com/erlang/rebar3/issues/1143.
            {ok, Cwd} = file:get_cwd(),
            file:set_cwd(ConfigPath),
            os:putenv("QUIET", "1"),
            MainCmd = io_lib:format("~p as ~p path", [Rebar3, Profile]),
            log("Call: ~s~n", [MainCmd]),
            {ExitCode, Output} = command(MainCmd, []),
            log("Result: ~p~n", [{ExitCode, Output}]),
            file:set_cwd(Cwd),

            Paths =
                case ExitCode of
                    0 ->
                        Output;
                    _ ->
                        file_error(
                          get(compiled_file_path),
                          {format,
                           "'~s' failed with exit code ~p: ~s~n",
                           [MainCmd, ExitCode, Output]}),
                        throw(error)
                end,

            CleanedPaths = [absname(ConfigPath, SubDir)
                            || SubDir <- string:tokens(Paths, " ")],
            code:add_pathsa(CleanedPaths),

            % Add _checkouts dependencies to code_path.
            %
            % These dependencies are compiled into the following directories:
            %
            % - `_checkouts/<app>/ebin' until rebar 3.13
            % - `_build/<profile>/checkouts/<app>/ebin/' from rebar 3.14
            %
            % Documentation for _checkouts dependencies:
            % https://www.rebar3.org/docs/dependencies#section-checkout-dependencies
            code:add_pathsa(
              filelib:wildcard(absname(ConfigPath, "_checkouts") ++
                               "/*/ebin")),
            code:add_pathsa(
              filelib:wildcard(absname(ConfigPath, "_build") ++
                               "/default/checkouts/*/ebin")),

            lists:foreach(
              fun({ProfileName, Deps}) ->
                      Apps = string:join([atom_to_list(D) || D <- Deps], ","),
                      file:set_cwd(ConfigPath),
                      Cmd2 = io_lib:format("QUIET=1 ~p as ~p path --app=~s",
                                          [Rebar3, ProfileName, Apps]),
                      log("Call: ~s~n", [Cmd2]),
                      ProfilePaths = os:cmd(Cmd2),
                      log("Result: ~s~n", [Paths]),
                      file:set_cwd(Cwd),
                      Cleaned = [absname(ConfigPath, SubDir)
                                 || SubDir <- string:tokens(ProfilePaths, " ")],
                      code:add_pathsa(Cleaned);
                 (_) -> ok
              end, rebar3_get_extra_profiles(Terms)),

            ErlOpts = proplists:get_value(erl_opts, Terms, []),
            remove_warnings_as_errors(ErlOpts)
    end.

%%------------------------------------------------------------------------------
%% @doc Find the rebar3 executable.
%%
%% First we try to find rebar3 in the project directory. Second we try to find
%% it in the PATH.
%% @end
%%------------------------------------------------------------------------------
-spec find_rebar3(ConfigPath) -> Result when
      ConfigPath :: [string()],
      Result :: {ok, string()} |
                not_found.
find_rebar3(ConfigPath) ->
    case find_files(ConfigPath, ["rebar3"]) of
        [Rebar3|_] ->
            {ok, Rebar3};
        [] ->
            case os:find_executable("rebar3") of
                false ->
                    not_found;
                Rebar3 ->
                    {ok, Rebar3}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Read the profile name defined in rebar.config for Rebar3
%%
%% Look inside rebar.config to find a special configuration called
%% `vim_erlang_compiler`.
%%
%% E.g. to use the "test" profile:
%%
%% ```
%% {vim_erlang_compiler, [
%%   {profile, "test"}
%% ]}.
%% '''
%%------------------------------------------------------------------------------
-spec rebar3_get_profile(Terms) -> Result when
      Terms :: [{atom(), term()}],
      Result :: string().
rebar3_get_profile(Terms) ->
  case proplists:get_value(vim_erlang_compiler, Terms) of
    undefined -> "default";
    Options -> proplists:get_value(profile, Options, "default")
  end.

%%------------------------------------------------------------------------------
%% @doc Read all extra profile names declared within the rebar.config
%%
%%------------------------------------------------------------------------------
-spec rebar3_get_extra_profiles(Terms) -> Result when
      Terms :: [{atom(), term()}],
      Result :: [{ProfileName :: string(),
                  [Dependency :: term()]}].
rebar3_get_extra_profiles(Terms) ->
    case proplists:get_value(profiles, Terms, []) of
        [] ->
            [];
        Profiles ->
            lists:flatmap(
              fun({ProfileName, Profile}) ->
                      case proplists:get_value(deps, Profile, []) of
                          [] ->
                              [];
                          Deps ->
                              [{ProfileName, [Dep || {Dep, _} <- Deps]}]
                      end;
                 (_) ->
                      []
              end, Profiles)
    end.

%%------------------------------------------------------------------------------
%% @doc Remove the "warnings_as_errors" option from the given Erlang options.
%%
%% If "warnings_as_errors" is left in, rebar sometimes prints the following
%% line:
%%
%%     compile: warnings being treated as errors
%%
%% The problem is that Vim interprets this as a line about an actual warning
%% about a file called "compile", so it will jump to the "compile" file.
%%
%% And anyway, it is fine to show warnings as warnings not not errors: the
%% developer knows whether their project handles warnings as errors and can
%% interpret them accordingly.
%% @end
%%------------------------------------------------------------------------------
-spec remove_warnings_as_errors(ErlOpts) -> ErlOpts when
      ErlOpts :: [{atom(), string()}].
remove_warnings_as_errors(ErlOpts) ->
    proplists:delete(warnings_as_errors, ErlOpts).

%%------------------------------------------------------------------------------
%% @doc Set code paths and options for a simple Makefile
%% @end
%%------------------------------------------------------------------------------
-spec load_makefiles(BuildFiles) -> Result when
      BuildFiles :: [string()],
      Result :: {opts, [{atom(), term()}]} |
                error.
load_makefiles([Makefile|_Rest]) ->
    Path = filename:dirname(Makefile),
    code:add_pathsa([absname(Path, "ebin")]),
    code:add_pathsa(filelib:wildcard(absname(Path, "deps") ++ "/*/ebin")),
    code:add_pathsa(filelib:wildcard(absname(Path, "lib") ++ "/*/ebin")),
    {opts, [{i, absname(Path, "include")},
            {i, absname(Path, "deps")},
            {i, absname(Path, "lib")}]}.

%%%=============================================================================
%%% Execution
%%%=============================================================================

-spec check_module_2(AbsFile, AbsDir, AppRoot, ProjectRoot,
                     Opts) -> Result when
      AbsFile :: string(),
      AbsDir :: string(),
      AppRoot :: string(),
      ProjectRoot :: string(),
      Opts ::  [{atom(), term()}],
      Result :: ok | error.
check_module_2(AbsFile, _AbsDir, AppRoot, ProjectRoot, Opts) ->

    Defs = [warn_export_all,
            warn_export_vars,
            warn_shadow_vars,
            warn_obsolete_guard,
            warn_unused_import,
            report,

            % Don't print part of the source code.
            %
            % By default, the compile:file/2 function in OTP 24+ prints not only
            % the error message but also a part of the source code by default.
            % E.g.:
            %
            %     /path/to/x.erl:19:7: syntax error before: MyVar
            %     || %   19|     x MyVar
            %     || %     |       ^
            %     || 
            %
            % The `brief' option disabled this.
            brief,

            % By adding debug_info, we ensure that the output of xref:m will
            % contain the caller MFAs too.
            debug_info],

    {ExtOpts, OutDir} = case get(outdir) of
                            undefined ->
                                {[strong_validation], undefined};
                            OutDir0 ->
                                AbsOutDir = filename:join(ProjectRoot, OutDir0),
                                {[{outdir, AbsOutDir}], AbsOutDir}
                        end,

    CompileOpts =
      Defs ++ Opts ++ ExtOpts ++
      [

       % rebar3/rebar_compiler_erl.erl adds <approot>/src, <approot>/include and
       % <approot> to the include path:
       %
       %    PrivIncludes = [{i, filename:join(OutDir, Src)}
       %                    || Src <- rebar_dir:all_src_dirs(
       %                                RebarOpts, ["src"], [])],
       %    AdditionalOpts =
       %        PrivIncludes ++
       %        [{i, filename:join(OutDir, "include")}, {i, OutDir}, return]
       %
       % So we do the same.

       {i, filename:join([AppRoot, "src"])},
       {i, filename:join([AppRoot, "include"])},
       {i, filename:join([AppRoot])}

      ],
    log("Code paths: ~p~n", [code:get_path()]),
    log("Compiling: compile:file(~p,~n    ~p)~n",
        [AbsFile, CompileOpts]),
    case compile:file(AbsFile, CompileOpts) of
        {ok, ModName} ->
            post_compilation(OutDir, ModName);
        error ->
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Perform tasks after successful compilation (xref, etc.)
%% @end
%%------------------------------------------------------------------------------
-spec post_compilation(AbsOutDir, ModName) -> ok when
      AbsOutDir :: string() | undefined,
      ModName :: module().
post_compilation(undefined, _ModName) ->
    ok;
post_compilation(AbsOutDir, ModName) ->
    BeamFileRoot = filename:join(AbsOutDir, atom_to_list(ModName)),
    maybe_run_xref(AbsOutDir, BeamFileRoot),
    code:add_patha(AbsOutDir),
    maybe_load(ModName),
    maybe_copy(BeamFileRoot, ModName),
    ok.

%%------------------------------------------------------------------------------
%% @doc Run xref on the given module and prints the warnings if the xref option
%% is specified.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_run_xref(AbsOutDir, BeamFileRoot) -> ok when
      AbsOutDir :: string(),
      BeamFileRoot :: string().
maybe_run_xref(AbsOutDir, BeamFileRoot) ->
    case get(xref) of
        true ->
            XRefWarnings = xref:m(BeamFileRoot),

            %% We add this directory to the code path because so that
            %% print_xref_warnings can find the beam file. It would not be good
            %% to add it before, because this directory might be e.g. /var/tmp
            %% so it could contain a bunch of outdates beam files, derailing
            %% xref.
            code:add_patha(AbsOutDir),

            print_xref_warnings(XRefWarnings);
        _ ->
            ok
    end.

%%------------------------------------------------------------------------------
%% @doc Print the warnings returned by xref to the standard output.
%% @end
%%------------------------------------------------------------------------------
-spec print_xref_warnings(XRefWarnings) -> ok when
      XRefWarnings :: [{deprecated, [{mfa(), mfa()}]} |
                       {undefined, [{mfa(), mfa()}]} |
                       {unused, [mfa()]}].
print_xref_warnings(XRefWarnings) ->
    {undefined, UndefFuns} = lists:keyfind(undefined, 1, XRefWarnings),
    [begin
         {CallerFile, CallerLine} = find_mfa_source(Caller),
         io:format("~s:~p: Warning: Calling undefined function ~p:~p/~p~n",
                   [CallerFile, CallerLine, M, F, A])
     end || {Caller, {M, F, A}} <- lists:reverse(UndefFuns)],
    ok.

%%------------------------------------------------------------------------------
%% @doc Given a MFA, find the file and LOC where it's defined.
%%
%% Note that xref doesn't work if there is no abstract_code, so we can avoid
%% being too paranoid here.
%%
%% This function was copied from rebar's source code:
%% https://github.com/basho/rebar/blob/117c0f7e698f735acfa73b116f9e38c5c54036dc/src/rebar_xref.erl
%%
%% @end
%%------------------------------------------------------------------------------
-spec find_mfa_source(MFA) -> Result when
      MFA :: mfa(),
      Result :: {FileName :: string(),
                 LineNumber :: integer()}.
find_mfa_source({M, F, A}) ->
    {M, Bin, _} = code:get_object_code(M),
    AbstractCode = beam_lib:chunks(Bin, [abstract_code]),
    {ok, {M, [{abstract_code, {raw_abstract_v1, Code}}]}} = AbstractCode,

    %% Extract the original source filename from the abstract code
    [{attribute, 1, file, {Source, _}} | _] = Code,

    %% Extract the line number for a given function def
    Fn = [E || E <- Code,
               safe_element(1, E) == function,
               safe_element(3, E) == F,
               safe_element(4, E) == A],

    case Fn of
        [{function, Line, F, _, _}] ->
            {Source, Line};
        [] ->
            %% Do not crash if functions are exported, even though they are not
            %% in the source. Parameterized modules add new/1 and instance/1 for
            %% example.
            {Source, 1}
    end.

%%------------------------------------------------------------------------------
%% @doc Load the given module if the `--load' option was specified.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_load(ModName) -> ok | error when
      ModName :: module().
maybe_load(ModName) ->
    case get(load) of
        {LongOrShortNames, MyNodeName, TargetNodeName} ->
            Cookie = get(cookie),
            load(LongOrShortNames, MyNodeName, TargetNodeName, Cookie, ModName);
        _ ->
            ok
    end.

%%------------------------------------------------------------------------------
%% @doc Load the given module into the given node.
%% @end
%%------------------------------------------------------------------------------
-spec load(LongOrShortNames, MyNodeName, TargetNodeName, Cookie,
           ModName) -> Result when
      LongOrShortNames :: shortnames | longnames,
      MyNodeName :: node(),
      TargetNodeName :: node(),
      Cookie :: atom(),
      ModName :: module(),
      Result :: ok | error.
load(LongOrShortNames, MyNodeName, TargetNodeName, Cookie, ModName) ->
    case code:get_object_code(ModName) of
        {ModName, BinaryMod, FileName} ->
            net_kernel:start([MyNodeName, LongOrShortNames]),
            case Cookie of
                undefined ->
                    ok;
                Cookie ->
                    erlang:set_cookie(TargetNodeName, Cookie)
            end,
            load_with_rpc(TargetNodeName, ModName, FileName, BinaryMod);
        error ->
            log_error("Failed to find object code for module ~p.~n", [ModName]),
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Load the given binary module into the given node.
%% @end
%%------------------------------------------------------------------------------
-spec load_with_rpc(Node, ModName, FileName, BinaryMod) -> Result when
      Node :: node(),
      ModName :: atom(),
      FileName :: string(),
      BinaryMod :: binary(),
      Result :: ok | error.
load_with_rpc(Node, ModName, FileName, BinaryMod) ->
    case rpc(Node, code, purge, [ModName]) of
        {ok, _} ->
            case rpc(Node, code, load_binary, [ModName, FileName, BinaryMod]) of
                {ok, {module, ModName}} ->
                    log("ModName ~p is reloaded~n", [ModName]),
                    ok;
                {ok, {error, Reason}} ->
                    log_error("Failed to load the module into node ~p: ~p~n",
                              [Node, Reason]),
                    error;
                {error, Reason} ->
                    log_error("RPC towards node ~p failed: ~p~n",
                              [Node, Reason]),
                    error
            end;
        {error, Reason} ->
            log_error("RPC towards node ~p failed: ~p~n", [Node, Reason]),
            error
    end.

%%------------------------------------------------------------------------------
%% @doc Copy the given module to module files with the same name if the --copy
%% option was specified.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_copy(BeamFileRoot, ModName) -> Result when
      BeamFileRoot :: string(),
      ModName :: module(),
      Result :: ok | error.
maybe_copy(BeamFileRoot, ModName) ->
    case get(copy) of
        TargetDir when is_list(TargetDir) ->
            copy(BeamFileRoot, ModName, TargetDir);
        _ ->
            ok
    end.

%%------------------------------------------------------------------------------
%% @doc Copy the given module to module files with the same name in the target
%% directory.
%% @end
%%------------------------------------------------------------------------------
-spec copy(BeamFileRoot, ModName, TargetDir) -> Result when
      BeamFileRoot :: string(),
      ModName :: module(),
      TargetDir :: string(),
      Result :: ok.
copy(BeamFileRoot, ModName, TargetDir) ->
    BeamFileBase = atom_to_list(ModName) ++ ".beam",
    SourceBeamFile = BeamFileRoot ++ ".beam",
    TargetBeamFiles = filelib:wildcard(
                        filename:join([TargetDir, "**", BeamFileBase])),
    [ case file:copy(SourceBeamFile, TargetBeamFile) of
          {ok, _} ->
              ok;
          Error ->
              log_error("Error when copying: ~p -> ~p: ~p~n",
                        [SourceBeamFile, TargetBeamFile, Error])
      end || TargetBeamFile <- TargetBeamFiles ],
    ok.

%%------------------------------------------------------------------------------
%% @doc Try to compile the given escript, print the warnings and errors, and
%% return whether there were errors.
%% @end
%%------------------------------------------------------------------------------
-spec check_escript(File) -> ok | error when
      File :: string().
check_escript(File) ->
    case command("escript -s " ++ File, [{print_output, true}]) of
        0 ->
            ok;
        _Other ->
            error
    end.

%%%=============================================================================
%%% Utility functions (in alphabetical order)
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Return the absolute name of the file which is in the given directory.
%%
%% Example:
%%
%% - cwd = "/home/my"
%% - Dir = "projects/erlang"
%% - Filename = "rebar.config"
%% - Result: "/home/my/projects/erlang/rebar.config"
%% @end
%%------------------------------------------------------------------------------
-spec absname(Dir, Filename) -> Result when
      Dir :: string(),
      Filename :: string(),
      Result :: string().
absname(Dir, Filename) ->
    filename:absname(filename:join(Dir, Filename)).

%%------------------------------------------------------------------------------
%% @doc Execute the given OS command.
%%
%% The command's output is printed, and its exit code is returned.
%%
%% Original code from
%% http://erlang.org/pipermail/erlang-questions/2007-February/025210.html
%% @end
%%------------------------------------------------------------------------------
-spec command(Cmd, Options) -> Result when
      Cmd :: string(),
      Options :: [{print_output, boolean()}],
      ExitCode :: integer(),
      Output :: string(),
      Result :: {ExitCode, Output}.
command(Cmd, Options) ->
     PortOptions = [stream, exit_status, use_stdio, stderr_to_stdout, in, eof],
     Port = open_port({spawn, Cmd}, PortOptions),
     command_loop(Port, Options, []).

%%------------------------------------------------------------------------------
%% @doc Read the output of an OS command started via a port.
%% @end
%%------------------------------------------------------------------------------
-spec command_loop(Port, Options, OutputAcc) -> Result when
      Port :: port(),
      Options :: [{print_output, boolean()}],
      OutputAcc :: [string()],
      ExitCode :: integer(),
      Output :: string(),
      Result :: {ExitCode, Output}.
command_loop(Port, Options, OutputAcc) ->
     receive
         {Port, {data, Data}} ->
             case proplists:get_value(print_output, Options, false) of
                 true ->
                     io:format(user, "~s", [Data]);
                 false ->
                     ok
             end,
             command_loop(Port, Options, [Data|OutputAcc]);
         {Port, eof} ->
             port_close(Port),
             receive
                 {Port, {exit_status, ExitCode}} ->
                     Output = lists:append(lists:reverse(OutputAcc)),
                     {ExitCode, Output}
             end
     end.

%%------------------------------------------------------------------------------
%% @doc Print the given error reason in a Vim-friendly and human-friendly way.
%% @end
%%------------------------------------------------------------------------------
-spec file_error(File, Error) -> ok when
      File :: string(),
      Error :: {format, Format, Data} |
               {file_error, FileError},
      Format :: io:format(),
      Data :: [term()],
      FileError :: file:posix() | badarg | terminated | system_limit |
                   {Line :: integer(), Mod :: module(), Term :: term()}.
file_error(File, Error) ->

    LineNumber =
        case Error of
            {file_error, {LineNumber0, _, _}} ->
                LineNumber0;
            _ ->
                % The error doesn't belong to a specific line, but Vim shows it
                % only if it has a line number, so let's assign line 1 to it.
                1
        end,

    FileRel = relatizive_path_maybe(File),
    io:format(standard_io, "~s:~p: ", [FileRel, LineNumber]),

    case Error of
        {file_error, FileError} ->
            io:format(standard_io, "~s~n", [file:format_error(FileError)]);
        {format, Format, Data} ->
            io:format(standard_io, Format, Data)
    end.

%%------------------------------------------------------------------------------
%% @doc Find the first file matching one of the filenames in the given path.
%% @end
%%------------------------------------------------------------------------------
-spec find_file(Path, Files) -> Result when
      Path :: string(),
      Files :: [string()],
      Result :: [string()].
find_file(_Path, []) ->
    [];
find_file(Path, [File|Rest]) ->
    AbsFile = absname(Path, File),
    case filelib:is_regular(AbsFile) of
        true ->
            log("Found build file: [~p] ~p~n", [Path, AbsFile]),
            % Return file and continue searching in parent directory.
            [AbsFile];
        false ->
            find_file(Path, Rest)
    end.

%%------------------------------------------------------------------------------
%% @doc Recursively search upward through the path tree and returns the absolute
%% path to all files matching the given filenames.
%% @end
%%------------------------------------------------------------------------------
-spec find_files(Path, Files) -> Result when
      Path :: string(),
      Files :: [string()],
      Result :: [string()].
find_files("/", Files) ->
    find_file("/", Files);
find_files([_|":/"] = Path, Files) ->
    % E.g. "C:/". This happens on Windows.
    find_file(Path, Files);
find_files(Path, Files) ->
    ParentPath = filename:dirname(Path),
    find_file(Path, Files) ++
    find_files(ParentPath, Files).

%%------------------------------------------------------------------------------
%% @doc Log the given entry if we are in verbose mode.
%% @end
%%------------------------------------------------------------------------------
-spec log(Format) -> ok when
      Format :: io:format().
log(Format) ->
    log(Format, []).

%%------------------------------------------------------------------------------
%% @doc Log the given entry if we are in verbose mode.
%% @end
%%------------------------------------------------------------------------------
-spec log(Format, Data) -> ok when
      Format :: io:format(),
      Data :: [term()].
log(Format, Data) ->
    case get(verbose) of
        true ->
            io:format(Format, Data);
        _ ->
            ok
    end.

%%------------------------------------------------------------------------------
%% @doc Log the given error.
%% @end
%%------------------------------------------------------------------------------
-spec log_error(Format) -> ok when
      Format :: io:format().
log_error(Format) ->
    io:format(standard_error, Format, []).

%%------------------------------------------------------------------------------
%% @doc Log the given error.
%% @end
%%------------------------------------------------------------------------------
-spec log_error(Format, Data) -> ok when
      Format :: io:format(),
      Data :: [term()].
log_error(Format, Data) ->
    io:format(standard_error, Format, Data).

%%------------------------------------------------------------------------------
%% @doc Try to convert a path to a relative path.
%% @end
%%------------------------------------------------------------------------------
-spec relatizive_path_maybe(Path) -> Path when
      Path :: file:filename().
relatizive_path_maybe(Path) ->
    {ok, Cwd} = file:get_cwd(),

    case lists:prefix(Cwd, Path) of
        true ->
            % Example:
            % Cwd = "/home/my"
            % Path = "/home/my/dir/my_file.erl"
            %                ^ length(Cwd)
            %                  ^ Start
            %                  <-------------> Len
            % FileRel = "dir/my_file.erl"
            Start = length(Cwd) + 2,
            Len = length(Path) - length(Cwd) - 1,
            lists:sublist(Path, Start, Len);
        false ->
            % The path is not below the current directory, so let's keep it
            % absolute.
            Path
    end.

%%------------------------------------------------------------------------------
%% @doc Perform a remote call towards the given node.
%% @end
%%------------------------------------------------------------------------------
-spec rpc(Node, M, F, A) -> Result when
      Node :: node(),
      M :: module(),
      F :: atom(),
      A :: integer(),
      Result :: {ok, term()} |
                {error, Reason :: {badrpc, term()}}.
rpc(Node, M, F, A) ->
    case rpc:call(Node, M, F, A) of
        {badrpc, _Reason} = Error ->
            {error, Error};
        Other ->
            {ok, Other}
    end.

%%------------------------------------------------------------------------------
%% @doc Extract an element from a tuple, or undefined if N > tuple size.
%%
%% This function was copied from rebar's source code:
%% https://github.com/basho/rebar/blob/117c0f7e698f735acfa73b116f9e38c5c54036dc/src/rebar_xref.erl
%%
%% @end
%%------------------------------------------------------------------------------
-spec safe_element(N, Tuple) -> term() when
      N :: number(),
      Tuple :: tuple().
safe_element(N, Tuple) ->
    case catch(element(N, Tuple)) of
        {'EXIT', {badarg, _}} ->
            undefined;
        Value ->
            Value
    end.
