//Written in the D programming language
// libdparse:
import std.d.lexer;
// std
import std.format;
@safe:

/// Symbol DAG element
class Symbol {
    string      file;
    string      name;
    Token[]     tokens;
    bool        gcUsed;
    //
    Symbol      parent;
    Symbol[]    children;

    @property size_t firstLine(){
        return tokens[0].line
    }

    @property size_t endLine(){
        return tokens[0].line
    }

    /// Dumps Graphviz format of this DAG
    void dump(scope void delegate (const(char)[]) sink){

    }
}

