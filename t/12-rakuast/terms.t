use MONKEY-SEE-NO-EVAL;
use Test;

plan 1;

{
    my $class = EVAL RakuAST::Package.new:
        scope => 'my',
        package-declarator => 'class',
        how => Metamodel::ClassHOW,
        name => RakuAST::Name.from-identifier('TestClass'),
        body => RakuAST::Block.new(body => RakuAST::Blockoid.new(RakuAST::StatementList.new(
            RakuAST::Statement::Expression.new(
                RakuAST::Method.new(
                    name => RakuAST::Name.from-identifier('meth-a'),
                    body => RakuAST::Blockoid.new(RakuAST::StatementList.new(
                        RakuAST::Statement::Expression.new(
                            RakuAST::IntLiteral.new(99)
                        )
                    ))
                )
            ),
            RakuAST::Statement::Expression.new(
                RakuAST::Method.new(
                    name => RakuAST::Name.from-identifier('meth-b'),
                    body => RakuAST::Blockoid.new(RakuAST::StatementList.new(
                        RakuAST::Statement::Expression.new(RakuAST::ApplyPostfix.new(
                            operand => RakuAST::Term::Self.new,
                            postfix => RakuAST::Call::Method.new(
                                name => RakuAST::Name.from-identifier('meth-a')
                            )
                        ))
                    ))
                )
            )
        )));
    is $class.meth-b(), 99, 'Method call via self works';
}
