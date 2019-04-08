
"""
Defines a fixture, that's called on every call to `@pytest` and calls
its set of dependency-fixtures.

Usage:
```
@fixture fixture_name function(other_fixture1, other_fixture2)
  # other_fixture1 holds the result of dependency other_fixture1
  do_sth_with(other_fixture1)
  do_sth_with(other_fixture2)
  # ...
  return fixture_results
end
```
"""
macro fixture(args...)
  fixture_function = args[end]

  # remaining middle arguments should be keyword arguments like params=(1, 2, 3)
  kwargs_expr = get_kwargs_expr(args[1:end-1])

  if fixture_function.head != :function || fixture_function.args[1].head != :call
    throw(ArgumentError("fixture_function should be a named function"))
  end

  # symbol of the fixture
  s_string = string(fixture_function.args[1].args[1])
  s = Symbol(s_string)

  fargs, escfargs = scan_for_fixtures(fixture_function)

  # NOTE 1: we need to be anonymized because named functions cannot be
  # inserted in Fixture constructor (see below)
  # NOTE 2: we need to change the name of the function, because @resumable registers the name
  fixture_function.args[1].args[1] = Symbol("_resumable_internal_" * s_string)

  anonymized_fixture_function =
    Expr(:macrocall,
         Symbol("@resumable"),
         fixture_function)

  quote
    # gather all dependency-fixtures from this fixture
    fixtures_dict = Dict{Symbol, Fixture}(zip($fargs, $escfargs))

    # build the Fixture instance and assign to the given variable
    kwargs = Dict{Symbol, Any}($kwargs_expr...)
    $(esc(s)) = Fixture($(s_string),
                        $(esc(anonymized_fixture_function)),
                        $fargs,
                        fixtures_dict,
                        kwargs)
  end
end

"""
Defines a single test, that calls its depenency-fixtures

Usage:
```
@pytest function(fixture1, fixture2)
  # fixture1 holds result of call to fixture1 etc
  do_sth_with(fixture1)
  # ... rest of test
end
```
"""
macro pytest(test_function)
  test_function.head in [:function, :->] || throw(ArgumentError("test_function should be a function"))
  if (test_function.args[1].head == :call)
    test_name = string(test_function.args[1].args[1])
  else
    test_name = "anonymous"
  end

  fargs, escfargs = scan_for_fixtures(test_function)

  return quote
    full_test_name = get_full_test_name(@__FILE__, $test_name)

    # only runs tests which name has been (partially) mentioned in test paths
    # or all tests if no test path specified
    if test_should_run(get(runner_args, "testpaths", []), full_test_name)
      run_pytest_test($(esc(test_function)), $escfargs, full_test_name)
    end
  end
end

# helpers

"Processes fixture arguments and extracts an expression with keyword arguments passed"
function get_kwargs_expr(keyword_args)
  kwargs_declarations = Array{Expr, 1}()
  for arg in keyword_args
    if !(:head in fieldnames(arg) && arg.head == :(=) && isa(arg.args[1], Symbol))
      throw(ArgumentError("middle arguments to @fixture must have a=b form"))
    end
    push!(kwargs_declarations, Expr(:call, :(=>), Expr(:quote, arg.args[1]), esc(arg.args[2])))
  end
  kwargs_expr = Expr(:vect, kwargs_declarations...)
end

"Returns true if test selection should make the test execute"
function test_should_run(testpaths, full_test_name)
  testpaths == [] || any((testpath) -> contains(full_test_name, testpath), testpaths)
end

"Discovers parametrizations of fixtures and runs fixture functions and test function"
function run_pytest_test(test_function, fixtures, full_test_name)
  parametrizations_matrix = get_param_matrix(fixtures)

  if isempty(parametrizations_matrix)
    do_single_test_run(fixtures, test_function, full_test_name)
  else
    for param_tuples in parametrizations_matrix
      param_set = Dict{Symbol, Any}(param_tuples)
      do_single_test_run(fixtures, test_function, "$full_test_name[$param_set]";
                         param_set=param_set)
    end
  end
end

"Runs test for a single setup of parameters"
function do_single_test_run(fixtures, test_function, displayable_test_name;
                            param_set=Dict{Symbol, Any}())

  # empty collection of fixtures' results
  results = Dict{Symbol, Any}()
  # empty collection of fixtures' teardown resumables (for pytest-style teardown)
  teardowns = Dict{Symbol, Teardown}()

  try
    # go through all fixtures used (recursively) and evaluate
    farg_results = [get_fixture_result(f, results, teardowns, param_set) for f in fixtures]

    @testset "$displayable_test_name" begin
      test_function(farg_results...)
    end
  finally
    [teardown_fixture(f, teardowns) for f in fixtures]
  end
end

"Based on filename of macro call and user-supplied name get a nice qualified test name"
function get_full_test_name(test_path, test_name)
  runtestdir = splitdir(test_path)
  test_file = runtestdir[2]
  relative_testdir = ""
  while runtestdir[1] != "/" && !isfile(joinpath(runtestdir[1], "runtests.jl"))
    runtestdir = splitdir(runtestdir[1])
    relative_testdir = joinpath(relative_testdir, runtestdir[2])
  end
  runtestdir[1] == "/" && error("unexpectedly found / when searching for tests root")
  relative_testfile = joinpath(relative_testdir, test_file)
  full_test_name = joinpath(relative_testfile, test_name)
end
get_full_test_name(test_path::Void, test_name) = "<repl>/$test_name"

"Convenience function to extract information from `@pytest` `@fixture` call"
function scan_for_fixtures(f)
  fargs = [farg for farg in f.args[1].args[1:end]]
  if f.args[1].head == :call
    deleteat!(fargs, 1)
  end

  escfargs = Expr(:vect, [esc(farg) for farg in fargs]...)
  fargs, escfargs
end

"Convenience function to call a single fixture, after all dependencies are called"
function get_fixture_result(fixture::Fixture, results::Dict{Symbol, Any},
                            teardowns::Dict{Symbol, Teardown},
                            param_set::Dict{Symbol, Any};
                            caller_name=Symbol(""))
  # FIXME: remove condition on :request, see also below
  if fixture.s in keys(results) && fixture.s != :request
    return results[fixture.s]
  end
  farg_results = [get_fixture_result(fixture.fixtures_dict[farg], results, teardowns, param_set;
                                     caller_name=fixture.s
                                     ) for farg in fixture.fargs]
  fixture_generator = (result for result in fixture.f(farg_results...))
  next_state = start(fixture_generator)
  done(fixture_generator, next_state)
  (new_result, next_state) = next(fixture_generator, next_state)

  # FIXME: refac to have RequestFixture? maybe...
  if fixture.s == :request && isa(new_result, Request)
    set_fixturename!(new_result, caller_name)
    if caller_name in keys(param_set)
      set_param!(new_result, param_set[caller_name])
    end
  end

  results[fixture.s] = new_result
  teardowns[fixture.s] = (fixture_generator, next_state)

  new_result
end

"Convenience function to call the teardown bits, after all dependencies got torn down"
function teardown_fixture(fixture::Fixture, teardowns::Dict{Symbol, Teardown})
  if !(fixture.s in keys(teardowns))
    return nothing
  end
  [teardown_fixture(fixture.fixtures_dict[farg], teardowns) for farg in fixture.fargs]

  teardown = teardowns[fixture.s]
  if(!done(teardown...))
    next(teardown...)
  end

  assert(done(teardown...))  # extra check just in case
  delete!(teardowns, fixture.s)
  nothing
end
