import std.stdio, std.algorithm, std.range, std.regex, std.exception;

void main(){
    auto lines = stdin.byLine.map!(x => x.idup).array;
    string[] record;
    foreach(i, line; lines){
        if(line.startsWith("!"))
            continue;
        if(line.startsWith("|-")){
            if(record.length && record[3].length){
                writeln(record[0],":", record[1], ":", record[3]);
            }
            record.length = 0;
            record.assumeSafeAppend();
            continue;
        }
        if(line.startsWith("|}"))
            break;
        auto m = line.matchFirst(`^\|\s*(.*)`);
        if(m)
            record ~= m[1];
    }
}