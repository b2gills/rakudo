my class Cursor does NQPCursorRole {
    has $!made; # Need it to survive re-creations of the match object.
    my @EMPTY_LIST;
    my $NO_CAPS := nqp::hash();

    multi method Bool(Cursor:D:) {
        nqp::getattr_i(self, Cursor, '$!pos') >= nqp::getattr_i(self, Cursor, '$!from')
    }

    method MATCH() {
        my $match := nqp::getattr(self, Cursor, '$!match');
        return $match if nqp::istype($match, Match) && nqp::isconcrete($match);
        $match := nqp::create(Match);
        nqp::bindattr($match, Match, '$!orig', nqp::findmethod(self, 'orig')(self));
        nqp::bindattr_i($match, Match, '$!from', nqp::getattr_i(self, Cursor, '$!from'));
        nqp::bindattr_i($match, Match, '$!to', nqp::getattr_i(self, Cursor, '$!pos'));
        nqp::bindattr($match, Match, '$!made', nqp::getattr(self, Cursor, '$!made'));
        nqp::bindattr($match, Match, '$!CURSOR', self);
        my Mu $list;
        my Mu $hash := nqp::hash();
        if $match.Bool {
            # For captures with lists, initialize the lists.
            my $caplist := $NO_CAPS;
            my $rxsub   := nqp::getattr(self, Cursor, '$!regexsub');
            if !nqp::isnull($rxsub) && nqp::defined($rxsub) {
                $caplist := nqp::can($rxsub, 'CAPS') ?? nqp::findmethod($rxsub, 'CAPS')($rxsub) !! nqp::null();
                if !nqp::isnull($caplist) && nqp::istrue($caplist) {
                    my $iter := nqp::iterator($caplist);
                    while $iter {
                        my $curcap := nqp::shift($iter);
                        if nqp::iterval($curcap) >= 2 {
                            my str $name = nqp::iterkey_s($curcap);
                            nqp::iscclass(nqp::const::CCLASS_NUMERIC, $name, 0)
                                ?? nqp::bindpos(
                                        nqp::defor($list, ($list := nqp::list())),
                                        +$name, nqp::list())
                                !! nqp::bindkey($hash, $name, []);
                        }
                    }
                }
            }

            # Walk the Cursor stack and populate the Cursor.
            my Mu $cs := nqp::getattr(self, Cursor, '$!cstack');
            if !nqp::isnull($cs) && nqp::istrue($cs) {
                my int $cselems = nqp::elems($cs);
                my int $csi = 0;
                while $csi < $cselems {
                    my $subcur   := $cs[$csi];
                    my $submatch := $subcur.MATCH;
                    my $name     := nqp::getattr($subcur, $?CLASS, '$!name');
                    if !nqp::isnull($name) && nqp::defined($name) {
                        if $name ne '' && nqp::ordat($name, 0) == 36 && ($name eq '$!from' || $name eq '$!to') {
                            nqp::bindattr_i($match, Match, $name, $submatch.from);
                        }
                        elsif nqp::index($name, '=') < 0 {
                            $submatch := nqp::islist($submatch)
                                ?? nqp::p6list($submatch, Array, Mu)
                                !! nqp::istype($submatch, Match)
                                    ?? $submatch
                                    !! [$submatch];
                            my int $needs_list = nqp::atkey($caplist, $name) >= 2;
                            if nqp::iscclass(nqp::const::CCLASS_NUMERIC, $name, 0) {
                                $list := nqp::list() unless nqp::isconcrete($list);
                                my int $pos = +$name;
                                $needs_list
                                    ?? nqp::push(nqp::atpos($list, $pos), $submatch)
                                    !! nqp::bindpos($list, $pos, $submatch);
                            }
                            else {
                                $needs_list
                                    ?? $hash{$name}.push($submatch)
                                    !! nqp::bindkey($hash, $name, $submatch);
                            }
                        }
                        else {
                            $submatch := nqp::islist($submatch)
                                ?? nqp::p6list($submatch, Array, Mu)
                                !! nqp::istype($submatch, Match)
                                    ?? $submatch
                                    !! [$submatch];
                            for nqp::split('=', $name) -> $name {
                                my int $needs_list = nqp::atkey($caplist, $name) >= 2;
                                if nqp::iscclass(nqp::const::CCLASS_NUMERIC, $name, 0) {
                                    $list := nqp::list() unless nqp::isconcrete($list);
                                    my int $pos = +$name;
                                    $needs_list
                                        ?? nqp::push(nqp::atpos($list, $pos), $submatch)
                                        !! nqp::bindpos($list, $pos, $submatch);
                                }
                                else {
                                    $needs_list
                                        ?? $hash{$name}.push($submatch)
                                        !! nqp::bindkey($hash, $name, $submatch);
                                }
                            }
                        }
                    }
                    $csi = nqp::add_i($csi, 1);
                }
            }
        }
        nqp::bindattr($match, Capture, '$!list', nqp::isconcrete($list) ?? $list !! @EMPTY_LIST);
        nqp::bindattr($match, Capture, '$!hash', $hash);
        nqp::bindattr(self, Cursor, '$!match', $match);

        # Once we've produced the captures, and if we know we're finished and
        # will never be backtracked into, we can release cstack and regexsub.
        unless nqp::defined(nqp::getattr(self, Cursor, '$!bstack')) {
            nqp::bindattr(self, Cursor, '$!cstack', nqp::null());
            nqp::bindattr(self, Cursor, '$!regexsub', nqp::null());
        }

        $match;
    }

    method MATCH_SAVE() {
        nqp::getattr_i(self, Cursor, '$!pos') < 0 ?? Nil !! self.MATCH()
    }

    # INTERPOLATE will iterate over the string $tgt beginning at position 0.
    # If it can't match against pattern $var (or any element of $var if it is an array)
    # it will increment $pos and try again. Therefor it is important to only match
    # against the current position.
    # $i is case insensitive flag
    # $s is for sequential matching instead of junctive
    # $a is true if we are in an assertion
    method INTERPOLATE($var, $i = 0, $s = 0, $a = 0) {
        if nqp::isconcrete($var) {
            # Call it if it is a routine. This will capture if requested.
            return $var(self) if $var ~~ Callable;
            my $maxlen := -1;
            my $cur := self.'!cursor_start_cur'();
            my $pos := nqp::getattr_i($cur, $?CLASS, '$!from');
            my $tgt := $cur.target;
            my $eos := nqp::chars($tgt);
            my Mu $nfa := QRegex::NFA.new;
            my $fate   := 0;
            my $count  := 0;
            my $start  := 1;
            my Mu $alts := nqp::list();
            my Mu $order := nqp::list();

            if nqp::istype($var, Positional) {
                if $s {
                    # The order matters for sequential matching, therefor no NFA involved.
                    $order := $var.list;
                }
                else {
                    # prepare to run the NFA if $var is array-ish.
                    for $var.list -> $topic {
                        nqp::push($alts, $topic);
                        if $a {
                            # We are in a regex assertion, the strings we get will be treated as
                            # regex rules.
                            return $cur.'!cursor_start_cur'() if $topic ~~ Associative;
                            my $rx := MAKE_REGEX($topic, :$i);
                            my Mu $nfas := nqp::findmethod($rx, 'NFA')($rx);
                            $nfa.mergesubstates($start, 0, $fate, $nfas, Mu);
                        }
                        elsif $topic ~~ Regex {
                            # A Regex already.
                            my Mu $nfas := nqp::findmethod($topic, 'NFA')($topic);
                            $nfa.mergesubstates($start, 0, $fate, $nfas, Mu);
                        }
                        else {
                            # The pattern is a string.
                            my Mu $lit  := QAST::Regex.new( :rxtype<literal>, $topic,
                                                            :subtype( $i ?? 'ignorecase' !! '') );
                            my Mu $nfa2 := QRegex::NFA.new;
                            my Mu $node := nqp::findmethod($nfa2, 'addnode')($nfa2, $lit);
                            my Mu $save := nqp::findmethod($node, 'save')($node, :non_empty(1));
                            $nfa.mergesubstates($start, 0, $fate, $save, Mu);
                        }
                        $fate := $fate + 1;
                    }

                    # Now run the NFA
                    my Mu $fates := nqp::findmethod($nfa, 'run')($nfa, $tgt, $pos);
                    $fate        := 0;
                    $count       := nqp::elems($fates);
                    while nqp::islt_i($fate, $count) {
                        my $thing := nqp::atpos_i($fates, $fate);
                        nqp::push($order, nqp::atpos($alts, $thing));
                        $fate := nqp::add_i($fate, 1);
                    }
                }
            }
            else {
                # Use the $var as it is if it's not array-ish.
                $order := $var;
            }

            for $order -> $topic {
                my $match;
                my $len;
                
                if $a {
                    # We are in a regex assertion, the strings we get will be treated as
                    # regex rules.
                    return $cur.'!cursor_start_cur'() if $topic ~~ Associative;
                    my $rx := MAKE_REGEX($topic, :$i);
                    $match := (nqp::substr($tgt, $pos, $eos - $pos) ~~ $rx).Str;
                    $len   := nqp::chars( $match );
                }
                elsif $topic ~~ Regex {
                    # A Regex already.
                    $match := nqp::substr($tgt, $pos, $eos - $pos) ~~ $topic;
                    
                    # In order to return the correct result we need to match from the
                    # current position only.
                    next if $match.from;
                    $match := ~$match;
                    $len   := nqp::chars( $match );
                }
                else {
                    # The pattern is a string.
                    my str $topic_str = $topic.Str;
                    $len   := nqp::chars( $topic_str );
                    $match := $len < 1
                            ||  ($i ?? nqp::lc(nqp::substr($tgt, $pos, $len)) eq nqp::lc($topic_str)
                                    !! nqp::substr($tgt, $pos, $len) eq $topic_str);
                }

                if $match && $len > $maxlen && $pos + $len <= $eos {
                    $maxlen := $len;
                    last if $s; # stop here for sequential alternation
                }
            }

            $cur.'!cursor_pass'($pos + $maxlen, '') if $maxlen >= 0;
            $cur
        }
        else {
            self."!cursor_start_cur"()
        }
    }

    method DYNQUANT_LIMITS($mm) {
        if $mm ~~ Range {
            die 'Range minimum in quantifier (**) cannot be +Inf' if $mm.min ==  Inf;
            die 'Range maximum in quantifier (**) cannot be -Inf' if $mm.max == -Inf;
            nqp::list_i($mm.min < 0 ?? 0 !! $mm.min.Int, $mm.max == Inf ?? -1 !! $mm.max.Int)
        }
        else {
            fail 'Fixed quantifier cannot be infinite' if $mm == -Inf || $mm == Inf;
            nqp::list_i($mm.Int, $mm.Int)
        }
    }

    method OTHERGRAMMAR($grammar, $name, |) {
        my $lang_cursor := $grammar.'!cursor_init'(self.target(), :p(self.pos()));
        $lang_cursor."$name"(); 
    }
    
    method INDRULE($rule, |c) {
        $rule(self, |c)
    }
    
    method RECURSE() {
        nqp::getlexdyn('$?REGEX')(self)
    }
}

sub MAKE_REGEX($arg, :$i) {
    my role CachedCompiledRegex {
        has $.regex;
    }
    if $arg ~~ Regex {
        $arg
    }
    elsif nqp::istype($arg, CachedCompiledRegex) {
        $arg.regex
    }
    else {
        my Mu $chars := nqp::split('', $arg);
        my $k := 0;
        my $iter := nqp::iterator($chars);
        while $iter {
            my $ord := nqp::ord( nqp::shift($iter) );
            nqp::bindpos($chars, $k, "\\c[$ord]") if $ord <= 32;
            $k := $k + 1;
        }
        my $arg2 := nqp::join('', $chars);
        my $rx := $i ?? EVAL("anon regex \{ :i ^$arg2\}") !! EVAL("anon regex \{ ^$arg2\}");
        $arg does CachedCompiledRegex($rx);
        $rx
    }
}

# vim: ft=perl6 expandtab sw=4
