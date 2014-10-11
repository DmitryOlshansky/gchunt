//Written in the D programming language
/++
    Generic recursive descent parser / pattern matcher.
    
    Works on any Forward range of any element type, provided
    there are basic matching blocks. For instance, it works 
    with any token type that has opEqual out of the box.

    The focus is on simplicity and flexibilty first,
    with speed being only 3rd on the list of priorities.

    API is heavily influenced by so-called parser combinators,
    a functional approach to parsing.
+/
module matcher;

import std.range;
debug(matcher) import std.stdio;

/// Simple regex on strings
unittest
{
    alias factory = matcherFactory!string;
    with(factory){        
        auto ab = any(token('a'), token('b'));
        // matcher = k(a|b)*c{3,}
        // better with insanely cool UFCS:
        auto matcher = seq(
            'k'.token,
            ab.star, 
            'c'.token.atLeast(3)
        );
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
    // our "token"
    struct Rec{
        string name;
        int value;
    }

    // pack few useful factory functions into a template
    // "extending" original matcherFactory 
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

///
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

/// True classics - arithmetic expression (and recursive matcher)
unittest
{
    import std.algorithm;
    alias factory = matcherFactory!(string);
    with(factory){
        // make some terminals with the help of cool D ranges
        auto id = 
            iota(cast(dchar)'a', 'z'+1)
            .chain(iota(cast(dchar)'0', '9'+1))
            .map!(x => x.token).array.any.atLeast(1);
        auto op1 = "-+".map!(x=>x.token).array.any;
        auto op2 = "*/".map!(x=>x.token).array.any;
        // we need to add an (expr) alternative later
        // so make prime an alternative with one matcher for now
        auto prime = seq('-'.token.optional, id).any;

        // easy testing of each individual production!
        assert("vaz190".matches(prime));
        assert("-var".matches(prime));

        // Just to show explicit tail-recursion... 
        // (it's better to simply use star here)
        auto head = seq(prime, op2);
        auto term = any(head, prime);
        // head = Prime [*/]
        // term = head | Prime
        // recursion via appending
        head ~= term;
        assert("a*c/-e".matches(term));

        // here we pick simpler
        auto expr = seq(term, seq(op1, term).star);
        // recursion via self-linking of seq 
        assert("-var1+var2*c-d".matches(expr));

        // Last piece - add parenthesized expression
        prime ~= seq('('.token, expr, ')'.token);
        assert("-var1+var2*(c-d*(a+e))-(c*e-12)".matches(expr));
    }
}

/// Generic matcher interface
interface Matcher(Stream)
    if(isForwardRange!Stream)
{
    alias S = Stream;
    alias M = Matcher;
    alias Tk = ElementType!Stream;
    /// on success advances the input, on failure leaves everything intact
    final bool opCall(ref S input){
        return match(input);
    }
    /// NVI idiom
    protected bool match(ref S input);
}

/// Test if range's head fits matcher's pattern
bool startsWith(R)(R s, Matcher!R m)
    if(isForwardRange!R)
{
    return m(s);
}

/// Test if the whole range fits matcher's pattern
bool matches(R)(R s, Matcher!R m)
    if(isForwardRange!R)
{
    return m(s) && s.length == 0;
}

/++
    Abstract generic matcher with multiple  
    sub-matchers and ability to manipulate them after construction.

    In particular this allows for self-referencing.
+/
abstract class MultiMatcher(Stream): Matcher!Stream {
    protected M[] matchers;
    protected this(M[] elements){
        matchers = elements;
    }
    /// Array-like set of primitives.
    public final M opIndex(size_t idx){
        return matchers[idx];
    }

    ///ditto
    public final M[] opSlice(){
        return matchers[0..$];
    }
    ///ditto
    public final M[] opSlice(size_t s, size_t e){
        return matchers[s..e];
    }

    ///ditto
    public final @property size_t length() {
        return matchers.length;
    }

    ///ditto
    public final MultiMatcher insert(size_t start, M[] elems...){
        import std.array;
        insertInPlace(matchers, start, elems);
        return this;
    }

    ///ditto
    public final MultiMatcher opOpAssign(string op)(M m)
        if(op == "~")
    {
        matchers ~= m;
        return this;
    }
}

/// Factory template - creates matchers for given Range type
/// and consequently element type.
/// 
//// Note it is perfectly fine to mixin this template for convenience.
template matcherFactory(Stream)
    if(isForwardRange!Stream)
{
    alias Tk = ElementType!Stream;
    alias M = Matcher!Stream;
    alias MM = MultiMatcher!Stream;
    alias S = Stream;
    /// Single-token matcher
    M token(Tk t){
        return new class M{
            bool match(ref S s){        
                if(!s.empty && s.front == t){
                    debug(matcher) writeln("Token ", t);
                    s.popFront();
                    return true;
                }
                else
                    return false;
            }
        };
    }

    M dot()
    {
        //TODO: could reuse one instance
        return new class M{
            bool match(ref Stream s){
                if(s.empty)
                    return false;
                else{
                    s.popFront();
                    return true;
                }
            }
        };
    }

    /// Any of matchers
    MM any(M[] mms...){
        return new class MM {
            this(){ super(mms.dup); }

            bool match(ref S s){
                foreach(i,m; matchers)
                    if(m(s)){
                        return true;
                    }
                return false;
            }
        };
    }

    /// Sequence
    MM seq(M[] mms...){
        return new class MM {
            this(){ super(mms.dup); }

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
        };
    }

    /// Any of matchers
    M atLeast(M matcher, uint n){
        return new class M {
            bool match(ref S s){
                auto t = s.save;
                for(uint i=0; i<n; i++)
                    if(!matcher(s)){
                        // restore state
                        if(i != 0)
                            s = t;
                        return false;
                    }
                // keep matching
                while(matcher(s)){}
                return true;
            }
        };
    }

    /// zero or one match
    M optional(M matcher){
        return new class M{
            bool match(ref S s){
                matcher(s);
                return true;
            }
        };
    }

    /// kleene-start of some expression
    M star(M matcher){
        return new class M {
            bool match(ref S s){
                // keep matching while we can
                while(matcher(s)){}
                // can exit with 0 matches
                return true;
            }
        };
    }

    static if(isRandomAccessRange!Stream && hasSlicing!Stream)
    M captureTo(Sink)(M matcher, Sink sink)
        if(isOutputRange!(Sink, Stream))
    {
        return new class M {
            bool match(ref S s){
                auto t = s.save;
                if(matcher(s)){
                    put(t[0 .. t.length - s.length], sink);
                    return true;
                }
                else
                    return false;
            }
        };
    }
}
