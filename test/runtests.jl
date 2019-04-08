reload("PyTest")
include("different_module.jl")

module tst

using PyTest

using Base.Test

@testset "PyTest tests" begin
  # FIXME: avoid this
  using ResumableFunctions

  include("base_fixtures.jl")
  include("exceptions.jl")
  include("request.jl")
  include("parametrized.jl")
  include("basetest_integration.jl")
  include("builtin/tempdir.jl")
  include("runner.jl")
end

end
