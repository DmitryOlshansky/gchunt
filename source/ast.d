//Written in the D programming language
// libdparse:
import dparse.lexer;
// std
import std.format;

/// Element of a DAG that represent lexical nesting.
class Ast {
private:
    string          file;
    string          name;
    const(Token)[]  tokens;
    bool            gcUsed;
    //
    Ast             parent;
    Ast[]           children;

    void dumpEdges(scope void delegate (const(char)[]) sink){
        foreach(c; children){
            formattedWrite(sink, `"%s" -> "%s";\n`, name, c.name);
            c.dumpEdges(sink);
        }
    }

public:
    this(string file, string name, const(Token)[] range, bool gc){
        this.file = file;
        this.name = name;
        this.tokens = range;
        this.gcUsed = gc;
    }

    @property size_t firstLine(){
        return tokens[0].line;
    }

    @property size_t endLine(){
        return tokens[0].line;
    }

    /// Analyze GC usage of any of the nested symbols
    bool analyzeGC(){
        foreach(c; children){
            if(c.analyzeGC){
                gcUsed = true;
                break;
            }
        }
        return false;
    }

    /// Dumps Graphviz format of this DAG
    void dump(scope void delegate (const(char)[]) sink){
        formattedWrite(sink, "graph {\n");
        dumpEdges(sink);
        formattedWrite(sink, "}\n");
    }
}

/// A cross-reference graph element
class Symbol{

}