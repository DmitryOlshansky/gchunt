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

// also advances token stream
bool locateMatching(ref Token[] stream, DMatcher matcher){
    int balance = 0; // dec on '}', inc on '{'
    for(;;){
        //HaCK: wild guess untill we parse constructors as well.
        // It does turn out to be true more often then not.
        if(stream.empty)
            break;
        if(stream.front.type == tok!"}"){
            stream.popFront();
            balance--;
        }
        else if(stream.front.type == tok!"{"){
            stream.popFront();
            balance++;
            if(balance > 0){
                if(matcher(stream))
                    return true;
            }
            balance = 0; // failed to match, again we must skip balanced pairs
        }
        else
            stream.popFront(); // next token
    }
    return false;
}

string locateFunction(ref Token[] tokens){
    string id;
    auto matcher = reverseFuncDeclaration((Token[] ts){
        if (ts[0].type == tok!"this")
            id = "this";
        else
            id = ts[0].text.dup;
    });
    if(locateMatching(tokens, matcher))
        return id;
    else
        return null;
}

string locateAggregate(ref Token[] tokens){
    string id;
    auto matcher = reverseAggregateDeclaration((Token[] ts){
        id = ts[0].text.dup;
    });
    if(locateMatching(tokens, matcher))
        return id;
    else
        return null;
}
/*
bool blockContains(Token[] blockStart, Token[] position)
{
    auto below = find!(x => x.type == tok!"{")(blockStart);
    int balance = 1;
    while(balance > 0 && !below.empty){
        if(below.front.type == tok!"}")
            balance--;
        else if(below.front.type == tok!"{")
            balance++;
        below.popFront();
    }
}*/

string findArtifact(ref Result r){
    auto tokens = tokenStreams[r.file];
    size_t start = to!size_t(r.line)-1;
    //BUG: libdparse only takes mutable bytes and returns const tokens?!! WAT, seriously
    auto tk_current = find!(t => t.line == start + 1)(tokens);
    auto upper_half = tokens[0 .. $ - tk_current.length];
    upper_half.reverse(); // look at it backwards
    // get id
    string id = locateFunction(upper_half);
    if(id is null)
        return "****"; // no idea...
    //now, from this point continue to search for aggregate if any
    string agg = locateAggregate(upper_half);
    if(agg !is null)
    {
        // test if aggregate contains original location
        auto below = find!(x => x.type == tok!"{")(tokens[upper_half.length .. $]);
        int balance = 1;
        while(balance > 0 && !below.empty){
            if(below.front.type == tok!"}")
                balance--;
            else if(below.front.type == tok!"{")
                balance++;
            below.popFront();
        }
        // ends lower then initial position - must be within
        if(below.length < tk_current.length)
            id = agg~"."~id;
    }
    return id;
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

Token[][string] tokenStreams;

// identified source-code entity
struct Artifact{
    int[] locs;
    string id;
    string mod;
    string[] reasons;
}

Artifact[string] artifacts;

version(unittest) void main(){}
else void main(){
    string fmt = "mediawiki";
    string gitHost = `https://github.com`;
    string gitHash = gitHEAD();
    string gitRepo = gitRemotePath();
    auto re = regex(`(.*[\\/]\w+)\.d\((\d+)\):\s*vgc:\s*(.*)`);
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
    auto interned = StringCache(4096);
    foreach(mod;results.map!(x => x.file).uniq){
        auto config = LexerConfig(mod~".d", StringBehavior.compiler);
        auto data = cast(ubyte[])std.file.read(mod ~ ".d");
        tokenStreams[mod] = getTokensForParser(data, config, &interned).dup;
    }
    foreach(r; results){
        //writeln(r.file, ",", r.line, ",", r.reason);
        auto mod = r.file.replace("/", ".");
        auto artifact = findArtifact(r);
        if(!artifact.endsWith("unittest")){
            auto path = mod~":"~artifact;
            if(path in artifacts){
                artifacts[path].locs ~= to!int(r.line);
            }
            else{
                artifacts[path] = Artifact([to!int(r.line)], artifact, mod);
            }
            if(!artifacts[path].reasons.canFind(r.reason))
                artifacts[path].reasons ~= r.reason;
        }
    }
    auto accum = artifacts.values();
    accum.sort!((a,b) => a.mod < b.mod || (a.mod == b.mod && a.id < b.id));

    string linkTemplate =
`[%s/%s/blob/%s/%s.d#L%s %d] `;
    writeln(`
{| class="wikitable"
! Module
! Artifact
! Reason
! Possible Fix(es)
|-`);
    stderr.writeln("Total number of GC-happy functions: ", accum.length);
    foreach(art; accum){
        art.reasons.sort();
        string reason = art.reasons.join(";\n");
        string links;
        foreach(i, loc; art.locs)
            links ~= format(linkTemplate, gitHost, gitRepo, gitHash, 
                art.mod.replace(".","/"), loc, i+1);
        writef("|%s\n|%s\n|%s\n| ???\n|-\n", art.mod, art.id, reason~"  "~links);
    }
    writeln("|}");
}