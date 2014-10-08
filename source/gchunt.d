/**
    gchunt - a tool to post-process -vgc compiler logs into 
    a neat report table with source links.

    Current use case - @nogc Phobos.
*/
//Written in the D programming language
module gchunt;

import std.conv, std.stdio, std.string, std.exception,
    std.regex, std.algorithm, std.range, std.process;

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
    auto lines = File(r.file ~ ".d")
        .byLine
        .map!(x => x.idup).array;
    size_t start = to!size_t(r.line)-1;
    // while indented at least once - step up!
    size_t current = walkUp(lines, 1, start);
    //now we are at top-most decl

    // Yet another hackish heuristic:
    // if it's a struct, class or tempalte
    // we need to re-walk again but with 2 indents ;)
    auto m = lines[current].matchFirst(`^(?:(?:@(?:trusted|safe)|nothrow|pure|final|abstract|private|public|package)\s*)*(?:struct|class|template)\s*(\w+)`);
    string parent = "";
    if(m)
    {
        parent = m[1];
        current = walkUp(lines, 2, start);
    }
    //r.line = to!string(current+1); // line number
    auto sig = lines[current].matchFirst(
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
    }
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
