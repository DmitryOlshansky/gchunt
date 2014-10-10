/++
    Generic recursive descent parser / pattern matcher.
    
    Works on any Forward range of any element type, provided
    there are basic matching blocks. For instance, it works 
    with any token type that has opEqual out of the box.

    The focus is on simplicity and flexibilty first,
    with speed being only 3rd on the list of priorities.
+/
module matcher;

import std.range;

/// Simple regex on strings
unittest
{
    alias factory = matcherFactory!string;
    with(factory){        
        auto ab = any(token('a'), token('b'));
        // matcher = k(a|b)*c{3,}
        auto matcher = seq(token('k'), star(ab), atLeast(3, token('c')));
        string s = "kabaabbbcccc";
        assert(matcher(s));
        assert(s.empty);
        s = "kabaabbbcc";
        assert(!matcher(s));
        // no match - no damage ;)
        assert(s == "kabaabbbcc");
    }
}

/// User-defined "token" & user-defined matcher
version(unittest)
{
    // Sadly UFCS is not supported for local functions
    // see neat usage of UFCS in the unittest block
    struct Rec{
        string name;
        int value;
    }

    // define our own matcher node
    @property auto value(int val){
        // anonymous class, quite handy
        return new class Matcher!(Rec[]){
            bool match(ref Rec[] r){
                if(r.length && r[0].value == val){
                    r = r[1..$];
                    return true;
                }
                // should not touch input on failure
                return false;
            }
        };
    }
    // ditto
    @property auto name(string s){
        return new class Matcher!(Rec[]){
            bool match(ref Rec[] r){
                if(r.length && r[0].name == s){
                    r = r[1..$];
                    return true;
                }
                // should not touch input on failure
                return false;
            }
        };
    }
}

unittest
{
    alias factory = matcherFactory!(Rec[]);
    auto records = [
        Rec("First", 4), Rec("second", 3), Rec("Third", 3),
        Rec("Forth", 3), Rec("Last", 8), Rec("???", 0)
    ];
    with(factory){
        auto matcher = seq(
            "First".name, 
            3.value.star, 
            Rec("Last", 8).token
        );
        assert(matcher(records));
        assert(records == [ Rec("???", 0) ]);
    }
}

/// Generic matcher interface
interface Matcher(Stream)
    if(isForwardRange!Stream)
{
    alias S = Stream;
    alias M = Matcher;
    alias Tk = ElementType!Stream;
    /// on success advances input, on failure leaves intact
    final bool opCall(ref S input){
        return match(input);
    }
    /// NVI idiom
    protected bool match(ref S input);
}

/// A simpliest matcher - just match a single token
class Fixed(Stream) : Matcher!Stream {
protected:
    Tk token;
    this(Tk token){
        this.token = token;
    }

    bool match(ref S s){        
        if(!s.empty && s.front == token){
            s.popFront();
            return true;
        }
        else
            return false;
    }
}

/// Match any from a list of matchers
class Any(Stream): Matcher!Stream {
protected:
    M[] matchers;

    this(M[] matchers)
    in{
        assert(matchers.length != 0);
    }body{
        this.matchers = matchers;
    }

    bool match(ref S s){
        foreach(m; matchers)
            if(m(s))
                return true;
        return false;
    }
}

/// Match any from a list of matchers
class Sequence(Stream): Matcher!Stream {
protected:
    M[] matchers;

    this(M[] matchers)
    in{
        assert(matchers.length != 0);
    }body{
        this.matchers = matchers;
    }

    /// To tweak after construction, in particular for self-referencing
    void append(M m){
        matchers ~= m;
    }

    bool match(ref S s){
        auto t = s.save;
        foreach(i, m; matchers)
            if(!m(s)){
                // restore state
                if(i != 0)
                    s = t;
                return false;
            }
        return true;
    }
}

/// klenee star of regex
class Star(Stream) : Matcher!Stream {
protected:
    M expr;
    this(M m){
        expr = m;
    }

    bool match(ref S s){
        // keep matching while we can
        while(expr(s)){}
        // can exit with 0 matches
        return true;
    }
}

/// {n, } of regex
class AtLeastN(Stream) : Matcher!Stream {
protected:
    M expr;
    uint count;

    this(uint n, M m){
        expr = m;
        count = n;
    }

    bool match(ref S s){
        auto t = s.save;
        for(uint n=0; n<count; n++)
            if(!expr(s)){
                // restore state
                if(n != 0)
                    s = t;
                return false;
            }
        // keep matching
        while(expr(s)){}
        return true;
    }
}

/// Factory template - creates matchers for given Range type
/// and consequently element type.
template matcherFactory(Stream)
    if(isForwardRange!Stream)
{
    alias Tk = ElementType!Stream;
    alias M = Matcher!Stream;
    alias S = Stream;
    /// Single-token matcher
    auto token(Tk t){
        return new Fixed!Stream(t);
    }

    /// Any of matchers
    auto any(M[] matchers...){
        // or we'd pass stack-allocated array
        return new Any!Stream(matchers.dup);
    }

    /// Sequence
    auto seq(M[] matchers...){
        // or we'd pass stack-allocated array
        return new Sequence!Stream(matchers.dup);
    }

    /// Any of matchers
    auto atLeast(uint n, M matcher){
        return new AtLeastN!Stream(n, matcher);
    }

    /// kleene-start of some expression
    auto star(M matcher){
        return new Star!Stream(matcher);
    }
}

