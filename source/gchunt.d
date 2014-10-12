//Written in the D programming language
/**
    gchunt - a tool to post-process -vgc compiler logs into 
    a neat report table with source links.

    Current use case - @nogc Phobos.
*/
module gchunt;

import std.algorithm, std.conv, std.stdio, std.string, std.exception,
    std.regex, std.range, std.process;

static import std.file;

// libdparse:
import std.d.lexer;
// our pattern matching on D tokens
import revdpattern;

struct Result{
    string file, line, reason;
}

string findAtrifact(ref Result r){
    auto data = cast(ubyte[])std.file.read(r.file ~ ".d");
    size_t start = to!size_t(r.line)-1;
    auto interned = StringCache(2048);
    auto config = LexerConfig(r.file~".d", StringBehavior.compiler);
    //BUG: libdparse only takes mutable bytes and returns const tokens?!! WAT, seriously
    auto tokens = getTokensForParser(data, config, &interned).dup;
    auto tk_current = find!(t => t.line == start + 1)(tokens);
    auto upper_half = tokens[0 .. $ - tk_current.length];
    upper_half.reverse(); // look at it backwards
    string id;
    // take reverse pattern-matcher
    auto matcher = reverseFuncDeclaration((Token[] ts){
        id = ts[0].text.dup;
    });
    int balance = 0; // dec on '}', inc on '{'
    for(;;){
        if(upper_half.empty)
            break;
        if(upper_half.front.type == tok!"}"){
            upper_half.popFront();
            balance--;
        }
        else if(upper_half.front.type == tok!"{"){
            upper_half.popFront();
            balance++;
            if(balance > 0){
                if(matcher(upper_half))
                    return id;
            }
            balance = 0; // failed to match, again we must skip balanced pairs
        }
        else
            upper_half.popFront(); // next token
    }
    //HaCK: wild guess untill we parse constructors as well.
    // It does turn out to be true more often then not.
    return "this";
}

string gitHEAD(){
    auto ret = execute(["git", "log"]);
    enforce(ret.status == 0);
    auto m = ret.output.matchFirst(`commit\s*([a-fA-F0-9]+)`);
    enforce(m, "broken git log");
    return m[1];
}

string gitRemotePath(){
    auto ret = execute(["git", "remote", "-v"]);
    enforce(ret.status == 0);
    auto m = ret.output.matchFirst(`origin\s*(.+) \(fetch\)`);
    enforce(m, "broken git log");
    //NOTE: matching others remotes can be hacked here
    m = m[1].matchFirst(`github.com[:/](.*)/(\S+)\.git`);
    enforce(m, "failed to find origin remote");
    return m[1]~"/"~m[2];
}

version(unittest) void main(){}
else void main(){
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