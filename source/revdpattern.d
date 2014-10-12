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
DFunc:
    (storageClass | type) Identifier templateParameters parameters 
    memberFunctionAttribute* constraint? 

But in reverse!
+/
DMatcher reverseFuncDeclaration(void delegate(Token[]) idSink=null){
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
        auto functionAttribute = any(atAttribute, dtok!"pure", dtok!"nothrow");
        auto memberFuncAttr = any(
            functionAttribute,
            dtok!"immutable",
            dtok!"inout",
            dtok!"shared",
            dtok!"const"
        );
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
        //attribute? type2 typeSuffix*
        type ~= revSeq(attribute.optional, type2, typeSuffix.star);

        version(unittest)
            type.checkRevParse();
        /++
         identifierOrTemplateInstance
         | '.' identifierOrTemplateInstance
         | basicType '.' Identifier
         | typeofExpression
         | typeidExpression
         | vector
         | arrayLiteral
         | assocArrayLiteral
         | '(' expression ')'
         | isExpression
         | lambdaExpression
         | functionLiteralExpression
         | traitsExpression
         | mixinExpression
         | importExpression
         | '$'
         | 'this'
         | 'super'
         | 'null'
         | 'true'
         | 'false'
         | '__DATE__'
         | '__TIME__'
         | '__TIMESTAMP__'
         | '__VENDOR__'
         | '__VERSION__'
         | '__FILE__'
         | '__LINE__'
         | '__MODULE__'
         | '__FUNCTION__'
         | '__PRETTY_FUNCTION__'
         | IntegerLiteral
         | FloatLiteral
         | StringLiteral+
         | CharacterLiteral
        +/
        auto block = revBalanced(dtok!"{", dtok!"}");
        auto funcContract = any(
            revSeq(dtok!"in", block.optional, dtok!"body"),
            revSeq(dtok!"out", revBalanced.optional, block.optional, dtok!"body"),
            revSeq(dtok!"in", block.optional, dtok!"out", revBalanced.optional, 
                block.optional, dtok!"body"),
        );
        auto primeExpr = any(
            dtok!"intLiteral", dtok!"characterLiteral",
            dtok!"stringLiteral", dtok!"floatLiteral",
            dtok!"__DATE__", dtok!"__EOF__", dtok!"__FILE__", dtok!"__FUNCTION__",
            dtok!"__PRETTY_FUNCTION__", dtok!"__TIME__", dtok!"__TIMESTAMP__",
            dtok!"__VENDOR__", dtok!"__VERSION__",
            dtok!"$", dtok!"this", dtok!"super", 
            dtok!"null", dtok!"true", dtok!"false",
            revSeq(builtinType, dtok!".", dtok!"identifier"),
            // typeid, typeof, vector, is, mixin, __traits expressions
            revSeq(
                any(
                    dtok!"typeid", dtok!"typeof", dtok!"__vector", 
                    dtok!"is", dtok!"mixin", dtok!"__traits"
                ),
                revBalanced
            ),
            //TODO: lambda expression
            // functionLiteral expression
            revSeq(
                revSeq(any(dtok!"function", dtok!"delegate"), type.optional).optional,
                revSeq(revBalanced, functionAttribute.star).optional,
                //in/out/body 
                funcContract.optional,
                block
            ),
            // array & AA literals
            revBalanced(dtok!"[", dtok!"]"),
            idOrTemplateChain,
            revBalanced // expression
        );
        version(unittest)
            primeExpr.checkRevParse(
                `int.abc`, `typeof(a.b)`, `ad!(ab,c)`, `(a+b*(cd()))`,
                `typeid(a+34231())`, `__vector()`, `is(a:b-)`,
                `(())`, `abc!(xa3()())`, `__traits(234134,fgd-9-=_())`,
                `()nothrow pure{ absfgsd ()[ }`, `function (int a){}`,
                `function {{}{}}`
            );

        auto unaryExpr = seq();
        /++
            baseClass:
                (typeofExpression '.')? identifierOrTemplateChain
            newExpression:
                'new' type ('[' assignExpression ']' | arguments)?
                | newAnonClassExpression
            newAnonClassExpression:
                'new' arguments? 'class' arguments? baseClassList? structBody
        +/
        auto baseClass = revSeq(
            revSeq(typeofExpression, dtok!".").optional, idOrTemplateChain
        );
         // core part of unary expr
        auto unaryExpr2 = any(
            revSeq(
                dtok!"new", type, 
                any(
                    revBalanced(dtok!"[", dtok!"]"), 
                    revBalanced.optional
                )
            ),
            revSeq(
                dtok!"new", revBalanced.optional, dtok!"class", revBalanced.optional, 
                // base classes list
                revSeq(baseClass, revSeq(dtok!",", baseClass).optional),
                // class body
                revBalanced(dtok!"{", dtok!"}")
            ),
            funcCallExpr,
            revSeq(
                dtok!"(", type, dtok!")", dtok!".",
                idOrTemplateChain
            ),
            revSeq(dtok!"assert", revBalanced),

            primeExpr // last thing to try
        );
        auto castQualifier = any(
            dtok!"const", dtok!"inout", dtok!"shared", dtok!"immutable", dtok!""
        ).star;
        // *-adornments on top of core unary expr
        unaryExpr ~= revSeq(
            any(      
                dtok!"&", dtok!"!",dtok!"*",dtok!"+",dtok!"-",dtok!"~",
                dtok!"++", dtok!"--", dtok!"delete",
                revSeq(
                    dtok!"cast", dtok!"(", 
                    any(type, castQualifier).optional, dtok!")"
                )
            ).star,
            unaryExpr2,
            any(
                dtok!"++", dtok!"--", 
                revSeq(dtok!".", idOrTemplateChain),
                // or slice/index exprs
                revBalanced(dtok!"[", dtok!"]")
            ).star
        );
      
        // unaryExpression templateArguments? arguments
        // | type arguments
        funcCallExpr ~= revSeq(
            unaryExpr, templateArguments.optional, revBalanced
        );
        funcCallExpr ~= revSeq(
            type, revBalanced
        );
        version(unittest)
            unaryExpr.checkRevParse(
            );
        auto functionId = dtok!"identifier";
        auto constructorId = dtok!"this";
        if(idSink != null){
            functionId = functionId.captureTo(idSink);
            constructorId = constructorId.captureTo(idSink);
        }

        auto constructoDecl = revSeq(
            constructorId,
            revBalanced.optional,
            revBalanced,
            memberFuncAttr.star,
            constraint.optional 
        );

        auto funcDecl = revSeq(
            any(storageClass, type),
            functionId,
            revBalanced.optional,
            revBalanced,
            memberFuncAttr.star,
            constraint.optional,
            funcContract.optional
        );
        return any(funcDecl, constructoDecl);
    }
}

/++
 classDeclaration:
       'class' Identifier (':' baseClassList)? ';'
     | 'class' Identifier (':' baseClassList)? structBody
     | 'class' Identifier templateParameters constraint? (':' baseClassList)? structBody
     | 'class' Identifier templateParameters (':' baseClassList)? constraint? structBody
structDeclaration:
     'struct' Identifier? (templateParameters constraint? structBody | (structBody | ';'))
in reverse
templateDeclaration
       'template' Identifier templateParameters constraint? '{' declaration* '}'
+/
auto reverseAggregateDeclaration(void delegate(Token[]) idSink=null){
    with(factory){
        auto templateArguments = revSeq(
            dtok!"!", any(
                revBalanced,
                dot // must be 2nd
            )
        );
        auto idOrTemplateChain = revSeq(
            dtok!"identifier",
            templateArguments.optional
        );
        auto constraint = revSeq(dtok!"if", revBalanced);
        auto baseClass = revSeq(
            revSeq(dtok!"typeof", revBalanced, dtok!".").optional, idOrTemplateChain
        );
        auto name = dtok!"identifier";
        if(idSink)
            name = name.captureTo(idSink);
        return any(
            revSeq(
                dtok!"class", name, revBalanced.optional, //template args
                constraint.optional, // constraint
                revSeq(
                    dtok!":", baseClass, revSeq(dtok!",", baseClass)
                ).optional, // base class list
                constraint.optional // another position for constraint
            ),
            revSeq(dtok!"struct",  name, revBalanced, constraint.optional),
            revSeq(dtok!"template", name, revBalanced, constraint.optional)
        );
    }
}

void checkRevParse(bool sucessful=true, size_t line = __LINE__)(DMatcher m, string[] dsource...){
    auto internCache = StringCache(2048);
    auto config = LexerConfig("test.d", StringBehavior.compiler);
    import std.conv;
    foreach(i,ds; dsource){
        //BUG: libdparse - mutable input but const output - this is nuts!
        TS ts = getTokensForParser(cast(ubyte[])ds.dup, 
            config, &internCache).dup;
        ts.reverse();
        assert(ts.matches(m) ^ !sucessful, 
            text("invoked on line ", line, " test #", i));
    }
}

unittest{
    with(factory)
        seq(dtok!")", dtok!"(").checkRevParse("()");
    revBalanced.checkRevParse("(a(+b)())");
    string[] ids;
    auto sink = (Token[] slice){
        assert(slice.length == 1);
        ids ~= slice[0].text.length ? slice[0].text.idup : str(slice[0].type).idup;
    };
    // also invokes lots of self-checks
    auto revParser = reverseFuncDeclaration(sink);
    revParser.checkRevParse(
`void topN(alias less = "a < b", Range)(Range r, size_t nth)
if (isRandomAccessRange!(Range) && hasLength!Range)`,
`public bool isKeyword(IdType type) pure nothrow @safe`,
`EditOp[] path()`,
`Cycle!R cycle(R)(R input, size_t index = 0)`,
`ForeachType!Range[] array(Range)(Range r)
if (isIterable!Range && !isNarrowString!Range && !isInfinite!Range)`,
`receiveOnlyRet!(T) receiveOnly(T...)() in{ assert(); }body`,
`void toString(scope void delegate(const(char)[]) sink, ref FormatSpec!char f) const`,
`this()`
    );
    assert(ids == ["topN", "isKeyword", "path", "cycle", "array", "receiveOnly",
        "toString", "this"]);
    revParser.checkRevParse!false(
`topN(alias less = "a < b", Range)(Range r, size_t nth)
if (isRandomAccessRange!(Range) && hasLength!Range)`,
`public bool isKeyword((IdType type) pure nothrow @safe`,
`public isKeyword(IdType type) pure nothrow @safe`,
`struct Levenshtein(Range, alias equals, CostType = size_t)`
    );
    // id's reached before failure are also added
    assert(ids == ["topN", "isKeyword", "path", "cycle", "array", "receiveOnly",
        "toString", "this", "topN", "isKeyword", "Levenshtein"]);
    ids = [];
    auto parseAgg = reverseAggregateDeclaration(sink);
    parseAgg.checkRevParse(
        `class A : B, c`, `struct Range(T) if( ABC())`,
        `class A if(R!C) : D,E`, `template XYZ() if()`
    );

    //TODO: fix captures
    assert(ids == ["A", "Range", "Range", "A", "XYZ","XYZ","XYZ"]);
}