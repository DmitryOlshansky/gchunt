//Written in the D programming language
/**
   Pattern-matching a subset of D grammar backwards.

*/
module revdpattern;

import std.algorithm, std.range;

// libdparse
import std.d.lexer;

import matcher;

alias TS = Token[]; // token stream
alias DMatcher = Matcher!TS;
alias factory = matcherFactory!TS;

auto reversed(T)(T[] arr){ 
    arr.reverse();
    return arr;
}

// reversed sequence combinator
auto revSeq(DMatcher[] matchers...){
    return factory.seq(matchers.reversed); // dups array inside
}

// Add some matchers
DMatcher dtok(string id)()
{
    return new class Matcher!(Token[]){
        bool match(ref TS ts){
            if(!ts.empty && ts[0].type == tok!id){
                ts.popFront();
                return true;
            }
            else
                return false;
        }
    };
}

// '(', something ()-balanced ')'
// matched in reverse!
DMatcher revBalanced(DMatcher opening=dtok!"(", DMatcher closing=dtok!")")
{
    return new class DMatcher{
        bool match(ref TS ts){
            size_t cnt = 0;
            if(!closing(ts))
                return false;
            for(;;){
                if(ts.empty)
                    return cnt == 0;
                if(closing(ts)){ // we go in reverse, so closing ++count
                    cnt++;
                }
                else if(opening(ts)){
                    if(cnt == 0) // note: consumed opening
                        return true;
                    cnt--;
                }
                else
                    ts.popFront();
            }
        }
    };
}

DMatcher builtinType(){
    return new class DMatcher{
        bool match(ref TS ts){
            if(ts.empty || !ts.front.type.isBasicType)
                return false;
            ts.popFront();
            return true;
        }
    };
}

/++
 unaryExpression:
       primaryExpression
     | '&' unaryExpression
     | '!' unaryExpression
     | '*' unaryExpression
     | '+' unaryExpression
     | '-' unaryExpression
     | '~' unaryExpression
     | '++' unaryExpression
     | '--' unaryExpression
     | newExpression
     | deleteExpression
     | castExpression
     | assertExpression
     | functionCallExpression
     | sliceExpression
     | indexExpression
     | '(' type ')' '.' identifierOrTemplateInstance
     | unaryExpression '.' identifierOrTemplateInstance
     | unaryExpression '--'
     | unaryExpression '++'
+/


DMatcher revAssignExpression(){
    with(factory){
        return dot; //FIXME
    }
}

/++
DFunc:
    (storageClass | type) Identifier templateParameters parameters 
    memberFunctionAttribute* constraint? 

But in reverse!
+/
DMatcher reverseFuncDeclaration(){
    with(factory){
        auto funcCallExpr = any();  // for referencing, will fill in later
        auto type = seq(); // ditto
        auto constraint = revSeq(
            dtok!"if", revBalanced
        );
        // '@' (Identifier | '(' argumentList ')' | functionCallExpression)
        auto atAttribute = revSeq(
            dtok!"@",
            any(
                dtok!"identifier",
                revBalanced,
                funcCallExpr
            )
        );
        
        //   '!' ('(' templateArgumentList? ')' | templateSingleArgument)")
        auto templateArguments = revSeq(
            dtok!"!", any(
                revBalanced,
                dot // must be 2nd
            )
        );

        version(unittest){
            constraint.checkRevParse(
                `if ( isInputRange!R && !is(ElementType!E : T))`
            );
            atAttribute.checkRevParse(
                `@myAttr`, `@(something ,wicked and ()-balanced)`
            );
            // can't test functionCall expr here, linked later
            templateArguments.checkRevParse(
                `!(a,b,c)`, `!zyx`, `!super`
            );
        }

        auto typeConstructor = any(dtok!"const", dtok!"immutable",
            dtok!"inout", dtok!"shared", dtok!"scope");
        /++
          atAttribute
         | typeConstructor
         | deprecated // deprecated ( ... )
         | 'abstract'
         | 'auto'
         | 'enum'
         | 'extern'
         | 'final'
         | 'nothrow'
         | 'override'
         | 'pure'
         | 'ref'
         | '__gshared'
         | 'scope'
         | 'static'
         | 'synchronized'
        +/
        auto storageClass = any(
            atAttribute,
            typeConstructor,
            revSeq(dtok!"deprecated", revBalanced),
            dtok!"abstract",
            dtok!"auto",
            dtok!"enum",
            dtok!"extern",
            dtok!"final",
            dtok!"nothrow",
            dtok!"override",
            dtok!"pure",
            dtok!"ref",
            dtok!"__gshared",
            dtok!"scope",
            dtok!"static",
            dtok!"synchronized"
        );
        version(unittest)
            storageClass.checkRevParse(
                `abstract`, `const`, `@uda`, `deprecated(xyz())`
            );
        /++
               alignAttribute   // align ( ... )
             | linkageAttribute // extern ( ... )
             | pragmaExpression // pragma ( ... )
             | storageClass
             | 'export'
             | 'package'
             | 'private'
             | 'protected'
             | 'public'
        +/
        auto attribute = any(
            revSeq(
                any(dtok!"align", dtok!"extern", dtok!"pragma"),
                revBalanced
            ),
            storageClass,
            dtok!"export",
            dtok!"package",
            dtok!"private",
            dtok!"protected",
            dtok!"public"
        );
        auto idOrTemplateChain = revSeq(
            dtok!"identifier",
            templateArguments.optional
        );

        version(unittest){
            attribute.checkRevParse(
                `export`, `public`, `align(45)`, `extern(()123)`,
                `pragma("afd", 3424, a*(-1212))`
            );
            idOrTemplateChain.checkRevParse(
                `abc`, `foo!bar`, `foo!(bar,why.in.the!hell)`
            );
        }
        auto symbol = revSeq(
            dtok!".".optional, idOrTemplateChain
        );
        // 'typeof' '(' (expression | 'return') ')'
        auto typeofExpression = revSeq(
            dtok!"typeof", revBalanced
        );
        // type2 -  core part, without suffix and attributes
        auto type2 = any(
            builtinType,
            revSeq(
                typeofExpression,
                revSeq(
                    dtok!".", idOrTemplateChain
                ).optional
            ),
            // symbol matches same tail as typeof branch, so must go lower
            symbol,
            revSeq(
                typeConstructor, dtok!"(", type, dtok!")"
            )
        );
        //can't test type-constructor part yet
        version(unittest)
            type2.checkRevParse(
                `.someSymbol!321`, `int`,   `typeof(some(()()(())),stuff)`,
                `typeof(return).name!foo`, `typeof(ac).xyz`, 
                `.name!(abc())`, `bar!yxz`
            );
        auto assignExpression = revAssignExpression;
        /++
             '*'
             | '[' type? ']' // fuck it, old attribute syntax
             | '[' assignExpression ']'
             | '[' assignExpression '..'  assignExpression ']'
             | ('delegate' | 'function') parameters memberFunctionAttribute*
        +/
        auto typeSuffix = any(
            dtok!"*",
            revBalanced(dtok!"[", dtok!"]"),
            revSeq(
                any(dtok!"delegate", dtok!"function"), revBalanced,

            )
        );

        auto memberFuncAttr = any(); // forward-ref
        auto primeExpr = any();
        auto unaryExpr = any();
        unaryExpr ~= revSeq(
            cast(DMatcher)any( // BUG: array literal type deduction in DMD
                dtok!"&", dtok!"!",dtok!"*",dtok!"+",dtok!"-",dtok!"~",
                dtok!"++", dtok!"--"
            ),
            unaryExpr
        );
        unaryExpr ~= revSeq(

        );
        
        //attribute? type2 typeSuffix*
        type ~= revSeq(attribute.optional, type2, typeSuffix.star);

        // unaryExpression templateArguments? arguments
        // | type arguments
        funcCallExpr ~= revSeq(
            unaryExpr, templateArguments.optional, revBalanced
        );
        funcCallExpr ~= revSeq(
            type, revBalanced
        );
        
        auto funcDecl = revSeq(
            any(storageClass, type),
            dtok!"identifier",
            revBalanced,
            revBalanced,
            memberFuncAttr.star,
            constraint.optional
        );
        return funcDecl;
    }
}

void checkRevParse(size_t line = __LINE__)(DMatcher m, string[] dsource...){
    auto internCache = StringCache(2048);
    auto config = LexerConfig("test.d", StringBehavior.compiler);
    import std.conv;
    foreach(i,ds; dsource){
        //BUG: libdparse - mutable input but const output - this is nuts!
        TS ts = getTokensForParser(cast(ubyte[])ds.dup, 
            config, &internCache).dup;
        ts.reverse();
        assert(ts.matches(m), text("invoked on line ", line, " test #", i));
    }
}

unittest{
    with(factory)
        seq(dtok!")", dtok!"(").checkRevParse("()");
    revBalanced.checkRevParse("(a(+b)())");
    // invokes lots of self-checks
    auto revParser = reverseFuncDeclaration();
}