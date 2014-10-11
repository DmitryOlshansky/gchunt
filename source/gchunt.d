/**
    gchunt - a tool to post-process -vgc compiler logs into 
    a neat report table with source links.

    Current use case - @nogc Phobos.
*/
//Written in the D programming language
module gchunt;

import std.conv, std.stdio, std.string, std.exception,
    std.regex, std.algorithm, std.range, std.process;

static import std.file;

import matcher;

// libdparse:
import std.d.lexer;

// Add some matchers
Matcher!(Token[]) dtok(string id)()
{
    return new class Matcher!(Token[]){
        bool match(ref Token[] ts){
            if(!ts.empty && ts[0].type == tok!id){
                ts.popFront();
                return true;
            }
            else
                return false;
        }
    };
}

Matcher!(Token[]) reverseDeclarationMatcher(){
    alias factory = matcherFactory!(Token[]);
    with(factory){
        auto expr = dtok!"!"; // FIXME!
        auto constraint = optional(seq(
            dtok!"if", dtok!"(", expr, dtok!")"
        ));
        return constraint;
    }
}

struct Result{
    string file, line, reason;
}

bool onlyKeywords(string line)
{
    return line.matchFirst(`^\s*(?:(?:@(?:trusted|safe)|final|pure|abstract|private|public|package|struct|class|template|nothrow)\s*)+$`)
        .length != 0;
}

size_t walkUp(string[] lines, int indent, size_t current)
{
// exploits Phobos style guide
// HACKISH :)
    string re = `^(    |\t){`~to!string(indent)~`}`;
   while(lines[current].matchFirst(re)
|| lines[current].matchFirst(`^\s*(?://|/\*|\*/|/\+|\+/)`) // comments
|| lines[current].matchFirst(`^\s*\w+:`) // label
|| lines[current].matchFirst(`^\s*(private|public):?\s*$`) // block scope
|| lines[current].onlyKeywords
|| lines[current].matchFirst(`^\s*(?:in|out|body|if|else|version)`) // if-constraint or (else)version ?
|| lines[current].matchFirst(`^\s*(?:\{|\})`) // brace on its line
|| !lines[current].length){  // empty line
        current--;
        if(current == 0) // can't find
            break;
    }
    return current;
}


string findAtrifact(ref Result r)
{
    auto data = cast(ubyte[])std.file.read(r.file ~ ".d");
    auto lines = (cast(string)data).split("\n");
    size_t start = to!size_t(r.line)-1;
    // while indented at least once - step up!
    size_t current = walkUp(lines, 1, start);
    //now we are at top-most decl

    // all above the current line
    string upper_half = join(lines[current..start]);
    string parent = "";
    auto interned = StringCache(2048);
    auto config = LexerConfig(r.file~".d", StringBehavior.compiler);

    //BUG: libdparse only takes mutable bytes ?!! WAT, seriously
    auto tokens = getTokensForParser(data,
        config, &interned);
    auto tk_upper = find!(t => t.line == current + 1)(tokens);
    auto tk_current = find!(t => t.line == start + 1)(tokens);
    assert(tk_upper.length > tk_current.length);
    auto len = tk_upper.length - tk_current.length;
    auto head = tk_upper[0..len];
    size_t balance = count(head.map!(x=>x.type), tok!"{") 
    - count(head.map!(x=>x.type), tok!"}");
    auto fullLen = len + 1 + countUntil!((x){
        if(x.type == tok!"{")
            balance++;
        else if(x.type == tok!"}")
            balance--;
        return balance == 0;
    })(tk_current);
    stderr.writeln(tk_upper[0..fullLen].map!(x => str(x.type)));
    //r.line = to!string(current+1); // line number
    /*auto sig = lines[current].matchFirst(
`^\s*(?:(?:private|public|package|static|final|@(?:property|safe|trusted|nogc|system)|template)\s*)*(\S+)(?:\s+(\w+))?`);
    if(!sig){
        stderr.writefln("%s.d(%s):***\t%s", r.file, r.line, lines[current]);
        return "****";
    }
    else{
        stderr.writeln(sig);
        string signature = sig[2].length ? sig[2] : sig[1];
        if(!signature.matchFirst(`^[\w()]+$`)){
            stderr.writefln("%s.d(%s):??? %s", r.file, r.line, lines[current]);
            return "****";
        }
        if(parent.length)
            signature = parent ~ "." ~ signature;

        return signature;
    }*/
    return "***";
}

string gitHEAD()
{
    auto ret = execute(["git", "log"]);
    enforce(ret.status == 0);
    auto m = ret.output.matchFirst(`commit\s*([a-fA-F0-9]+)`);
    enforce(m, "broken git log");
    return m[1];
}

string gitRemotePath()
{
    auto ret = execute(["git", "remote", "-v"]);
    enforce(ret.status == 0);
    auto m = ret.output.matchFirst(`origin\s*(.+) \(fetch\)`);
    enforce(m, "broken git log");
    //NOTE: matching others remotes can be hacked here
    m = m[1].matchFirst(`github.com[:/](.*)/(\S+)\.git`);
    enforce(m, "failed to find origin remote");
    return m[1]~"/"~m[2];
}

version(unittest)
    void main(){}
else
void main(){
    string fmt = "mediawiki";
    string gitHost = `https://github.com`;
    string gitHash = gitHEAD();
    string gitRepo = gitRemotePath();
    auto re = regex(`(.*[\\/]\w+)\.d\((\d+)\):\s*vgc:\s*(.*)`);
    //writeln(`std\variant.d(236): vgc: 'new' causes GC allocation`.match(re));
    Result[] results;
    foreach(line; stdin.byLine){
        auto m = line.idup.matchFirst(re);
        if(m){
            results ~= Result(m[1].replace("\\", "/"), m[2], m[3]);
        }
    }
    sort!((a,b) => a.file < b.file || (a.file == b.file && a.line < b.line))
        (results);
    results = uniq(results).array;

    string linkTemplate =
`[%s/%s/blob/%s/%s.d#L%s %s]`;
    writeln(`
{| class="wikitable"
! Module
! Artifact
! Reason
! Possible Fix(es)
|-`);
    foreach(r; results){
        //writeln(r.file, ",", r.line, ",", r.reason);
        auto mod = r.file.replace("/", ".");
        auto artifact = findAtrifact(r);
        if(!artifact.endsWith("unittest")){
            auto link = format(linkTemplate, gitHost, gitRepo, gitHash, r.file, r.line, mod);
            writef("|%s\n|%s\n|%s\n| ???\n|-\n", link, artifact, r.reason);
        }
    }
    writeln("|}");
}