//Written in the D programming language

// libdparse:
import dparse.lexer;

import matcher;

import std.range;

alias TS = Token[]; // token stream
alias DMatcher = Matcher!TS;
alias factory = matcherFactory!TS;

void checkParse(bool sucessful=true, size_t line = __LINE__)(DMatcher m, string[] dsource...){
    auto internCache = StringCache(2048);
    auto config = LexerConfig("test.d", StringBehavior.compiler);
    import std.conv;
    foreach(i,ds; dsource){
        //BUG: libdparse - mutable input but const output - this is nuts!
        TS ts = getTokensForParser(cast(ubyte[])ds.dup, 
            config, &internCache).dup;
        assert(ts.matches(m) ^ !sucessful,
            text("invoked on line ", line, " test #", i));
    }
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
DMatcher balanced(DMatcher opening=dtok!"(", DMatcher closing=dtok!")")
{
    return new class DMatcher{
        bool match(ref TS ts){
            size_t cnt = 0;
            if(!opening(ts))
                return false;
            for(;;){
                if(ts.empty)
                    return cnt == 0;
                if(closing(ts)){
                    cnt--;
                }
                else if(closing(ts)){
                    if(cnt == 0) // note: consumed closing
                        return true;
                    cnt++;
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
+/
DMatcher funcDeclaration(void delegate(Token[]) idSink=null){
    with(factory){
        auto funcCallExpr = any();  // for referencing, will fill in later
        auto type = seq(); // ditto
        auto constraint = seq(
            dtok!"if", balanced
        );
        // '@' (Identifier | '(' argumentList ')' | functionCallExpression)
        auto atAttribute = seq(
            dtok!"@",
            any(
                dtok!"identifier",
                balanced,
                funcCallExpr
            )
        );
        
        //   '!' ('(' templateArgumentList? ')' | templateSingleArgument)")
        auto templateArguments = seq(
            dtok!"!", any(
                balanced,
                dot // must be 2nd
            )
        );

        version(unittest){
            constraint.checkParse(
                `if ( isInputRange!R && !is(ElementType!E : T))`
            );
            atAttribute.checkParse(
                `@myAttr`, `@(something ,wicked and ()-balanced)`
            );
            // can't test functionCall expr here, linked later
            templateArguments.checkParse(
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
            seq(dtok!"deprecated", balanced),
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
            storageClass.checkParse(
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
            seq(
                any(dtok!"align", dtok!"extern", dtok!"pragma"),
                balanced
            ),
            storageClass,
            dtok!"export",
            dtok!"package",
            dtok!"private",
            dtok!"protected",
            dtok!"public"
        );
        auto idOrTemplateChain = seq(
            dtok!"identifier",
            templateArguments.optional
        );

        version(unittest){
            attribute.checkParse(
                `export`, `public`, `align(45)`, `extern(()123)`,
                `pragma("afd", 3424, a*(-1212))`
            );
            idOrTemplateChain.checkParse(
                `abc`, `foo!bar`, `foo!(bar,why.in.the!hell)`
            );
        }
        auto symbol = seq(
            dtok!".".optional, idOrTemplateChain
        );
        // 'typeof' '(' (expression | 'return') ')'
        auto typeofExpression = seq(
            dtok!"typeof", balanced
        );
        // type2 -  core part, without suffix and attributes
        auto type2 = any(
            // symbol matches same tail as typeof branch, so must go lower
            symbol,
            builtinType,
            seq(
                typeofExpression,
                seq(
                    dtok!".", idOrTemplateChain
                ).optional
            ),
            seq(
                typeConstructor, dtok!"(", type, dtok!")"
            )
        );
        //can't test type-constructor part yet
        version(unittest)
            type2.checkParse(
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
            balanced(dtok!"[", dtok!"]"),
            seq(
                any(dtok!"delegate", dtok!"function"), balanced,
            )
        );
        //attribute? type2 typeSuffix*
        type ~= seq(attribute.optional, type2, typeSuffix.star);

        version(unittest)
            type.checkParse();
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
        auto block = balanced(dtok!"{", dtok!"}");
        auto funcContract = any(
            seq(dtok!"in", block.optional, dtok!"out", balanced.optional, 
                block.optional, dtok!"body"),
            seq(dtok!"in", block.optional, dtok!"body"),
            seq(dtok!"out", balanced.optional, block.optional, dtok!"body"),
        );
        auto primeExpr = any(
            dtok!"intLiteral", dtok!"characterLiteral",
            dtok!"stringLiteral", dtok!"floatLiteral",
            dtok!"__DATE__", dtok!"__EOF__", dtok!"__FILE__", dtok!"__FUNCTION__",
            dtok!"__PRETTY_FUNCTION__", dtok!"__TIME__", dtok!"__TIMESTAMP__",
            dtok!"__VENDOR__", dtok!"__VERSION__",
            dtok!"$", dtok!"this", dtok!"super", 
            dtok!"null", dtok!"true", dtok!"false",
            seq(builtinType, dtok!".", dtok!"identifier"),
            // typeid, typeof, vector, is, mixin, __traits expressions
            seq(
                any(
                    dtok!"typeid", dtok!"typeof", dtok!"__vector", 
                    dtok!"is", dtok!"mixin", dtok!"__traits"
                ),
                balanced
            ),
            //TODO: lambda expression
            // functionLiteral expression
            seq(
                seq(any(dtok!"function", dtok!"delegate"), type.optional).optional,
                seq(balanced, functionAttribute.star).optional,
                //in/out/body 
                funcContract.optional,
                block
            ),
            // array & AA literals
            balanced(dtok!"[", dtok!"]"),
            idOrTemplateChain,
            balanced // expression
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
        auto baseClass = seq(
            seq(typeofExpression, dtok!".").optional, idOrTemplateChain
        );
         // core part of unary expr
        auto unaryExpr2 = any(
            seq(
                dtok!"new", type, 
                any(
                    balanced(dtok!"[", dtok!"]"), 
                    balanced.optional
                )
            ),
            seq(
                dtok!"new", balanced.optional, dtok!"class", balanced.optional, 
                // base classes list
                seq(baseClass, seq(dtok!",", baseClass).optional),
                // class body
                balanced(dtok!"{", dtok!"}")
            ),
            funcCallExpr,
            seq(
                dtok!"(", type, dtok!")", dtok!".",
                idOrTemplateChain
            ),
            seq(dtok!"assert", balanced),

            primeExpr // last thing to try
        );
        auto castQualifier = any(
            dtok!"const", dtok!"inout", dtok!"shared", dtok!"immutable", dtok!""
        ).star;
        // *-adornments on top of core unary expr
        unaryExpr ~= seq(
            any(      
                dtok!"&", dtok!"!",dtok!"*",dtok!"+",dtok!"-",dtok!"~",
                dtok!"++", dtok!"--", dtok!"delete",
                seq(
                    dtok!"cast", dtok!"(", 
                    any(type, castQualifier).optional, dtok!")"
                )
            ).star,
            unaryExpr2,
            any(
                dtok!"++", dtok!"--", 
                seq(dtok!".", idOrTemplateChain),
                // or slice/index exprs
                balanced(dtok!"[", dtok!"]")
            ).star
        );
      
        // unaryExpression templateArguments? arguments
        // | type arguments
        funcCallExpr ~= seq(
            unaryExpr, templateArguments.optional, balanced
        );
        funcCallExpr ~= seq(
            type, balanced
        );
        version(unittest)
            unaryExpr.checkParse(
            );
        auto functionId = dtok!"identifier";
        auto constructorId = dtok!"this";
        if(idSink != null){
            functionId = functionId.captureTo(idSink);
            constructorId = constructorId.captureTo(idSink);
        }

        auto constructoDecl = seq(
            constructorId,
            balanced.optional,
            balanced,
            memberFuncAttr.star,
            constraint.optional 
        );

        auto funcDecl = seq(
            any(storageClass, type),
            functionId,
            balanced.optional,
            balanced,
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
auto aggregateDeclaration(void delegate(Token[]) idSink=null){
    with(factory){
        auto templateArguments = seq(
            dtok!"!", any(
                balanced,
                dot // must be 2nd
            )
        );
        auto idOrTemplateChain = seq(
            dtok!"identifier",
            templateArguments.optional
        );
        auto constraint = seq(dtok!"if", balanced);
        auto baseClass = seq(
            seq(dtok!"typeof", balanced, dtok!".").optional, idOrTemplateChain
        );
        auto name = dtok!"identifier";
        if(idSink)
            name = name.captureTo(idSink);
        return any(
            seq(
                dtok!"class", name, balanced.optional, //template args
                constraint.optional, // constraint
                seq(
                    dtok!":", baseClass, seq(dtok!",", baseClass)
                ).optional, // base class list
                constraint.optional // another position for constraint
            ),
            seq(dtok!"struct",  name, balanced.optional, constraint.optional),
            seq(dtok!"template", name, balanced.optional, constraint.optional)
        );
    }
}

unittest{
    with(factory)
        seq(dtok!"(", dtok!")").checkParse("()");
    balanced.checkParse("(a(+b)())");
    string[] ids;
    auto sink = (Token[] slice){
        assert(slice.length == 1);
        ids ~= slice[0].text.length ? slice[0].text.idup : str(slice[0].type).idup;
    };
    // also invokes lots of self-checks
    auto parser = funcDeclaration(sink);
    parser.checkParse(
`void topN(alias less = "a < b", Range)(Range r, size_t nth)
if (isRandomAccessRange!(Range) && hasLength!Range)`,
`public bool isKeyword(IdType type) pure nothrow @safe`,
`EditOp[] path()`,
`Cycle!R cycle(R)(R input, size_t index = 0)`,
`ForeachType!Range[] array(Range)(Range r)
if (isIterable!Range && !isNarrowString!Range && !isInfinite!Range)`,
`receiveOnlyRet!(T) receiveOnly(T...)() in{ assert(); }body`,
`void toString(scope void delegate(const(char)[]) sink, ref FormatSpec!char f) const`,
`this()`,
`void reserve(size_t nbytes)
in
{
assert(offset + nbytes >= offset);
}
out
{
assert(offset + nbytes <= data.length);
}
body
`);
    assert(ids == ["topN", "isKeyword", "path", "cycle", "array", "receiveOnly",
        "toString", "this", "reserve"]);
    ids = [];
    revParser.checkParse!false(
`topN(alias less = "a < b", Range)(Range r, size_t nth)
if (isRandomAccessRange!(Range) && hasLength!Range)`,
`public bool isKeyword((IdType type) pure nothrow @safe`,
`public isKeyword(IdType type) pure nothrow @safe`,
`struct Levenshtein(Range, alias equals, CostType = size_t)`
    );
    // id's reached before failure are also added
    assert(ids == ["topN", "isKeyword", "Levenshtein"]);
    ids = [];
    auto parseAgg = reverseAggregateDeclaration(sink);
    parseAgg.checkRevParse(
        `class A : B, c`, `struct Range(T) if( ABC())`,
        `class A if(R!C) : D,E`, `template XYZ() if()`,
        `template WriteToString()`
    );
    //TODO: fix captures
    assert(ids == ["A", "Range", "Range", "A", "XYZ","XYZ","XYZ", 
        "WriteToString", "WriteToString", "WriteToString"]);
}