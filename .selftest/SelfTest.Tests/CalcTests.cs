using SelfTest.Lib;

namespace SelfTest.Tests;

public class CalcTests
{
    [Fact]
    public void Add_Works() => Assert.Equal(3, Calc.Add(1, 2));

    // Stands in for a Testcontainers test that can't run on the runner; must be excluded by test-filter.
    [Fact, Trait("Category", "Integration")]
    public void Integration_AlwaysFails() => Assert.Fail("Integration tests must be filtered out");
}
