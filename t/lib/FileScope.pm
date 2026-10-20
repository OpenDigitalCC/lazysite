package FileScope;

# THE FILE-SCOPE SCAN, shared by t/lint/269 (SM1169: what a pooled worker keeps
# resident) and t/lint/272 (SM1226: what the Odoo endpoint's warm-fork parent
# holds). Moved here from t/lint/269 unchanged.
#
# A source scan, not PPI (not a dependency): file scope is "outside every sub",
# found by counting braces over the code with strings, comments, pod and
# heredocs removed. t/lint/215 makes the same trade for the script's own `my`s.
use strict;
use warnings;
use Exporter qw(import);
our @EXPORT_OK = qw(code_lines file_scope_decls literal_init);

# The code of a file as a list of [line_number, text], with pod, whole-line and
# trailing comments, heredoc bodies and string literals removed, so that braces
# and `my` can be read from what is left. A string keeps a placeholder ("S") so
# the shape of a statement survives.
sub code_lines {
    my ($text) = @_;
    my @out;
    my ( $in_pod, $heredoc ) = ( 0, undef );
    my $n = 0;
    for my $raw ( split /\n/, $text, -1 ) {
        $n++;
        last if $raw =~ /^__(?:END|DATA)__\b/;
        if ($in_pod) { $in_pod = 0 if $raw =~ /^=cut\b/; next }
        if ( $raw =~ /^=[a-zA-Z]/ ) { $in_pod = 1; next }
        if ( defined $heredoc ) {
            my $t = $raw;
            $t =~ s/^\s+// if $heredoc->{indent};
            $heredoc = undef if $t eq $heredoc->{tag};
            next;
        }
        my $l = $raw;
        next if $l =~ /^\s*#/;
        my $hd;
        if ( $l =~ /<<(~?)(?:'([A-Z_][A-Z0-9_]*)'|"([A-Z_][A-Z0-9_]*)"|([A-Z_][A-Z0-9_]*))/ ) {
            $hd = { tag => $2 // $3 // $4, indent => $1 ? 1 : 0 };
        }
        # string literals first, so a # or a brace inside one is not read as code
        $l =~ s/'(?:[^'\\]|\\.)*'/S/g;
        # an interpolating string is not a literal: it keeps a $ that says so (SV)
        $l =~ s/"((?:[^"\\]|\\.)*)"/ my $s = $1; $s =~ m{(?<!\\)[\$\@]\w} ? '$INTERPOLATED' : 'S' /ge;
        $l =~ s/\s+#.*$//;
        $heredoc = $hd if $hd;
        push @out, [ $n, $l ];
    }
    return @out;
}

# Every declaration made outside any sub: [ line, kind, sigil.name, statement ].
# kind is my | our. The statement is the code from the declaration to its `;`,
# strings as S.
sub file_scope_decls {
    my ($text) = @_;
    my @lines = code_lines($text);
    # A stack of blocks. A sub's own block is skipped. A `my` in any other block
    # is scoped to it and dies with it, unless the block holds a sub (the bare
    # block idiom: `{ my %cache; sub f { ... } }`), whose closure keeps it alive.
    my @stack = ( { sub => 0, has_sub => 1, decls => [] } );    # file level: always kept
    my @decls;
    my $pending_sub = 0;
    for ( my $i = 0 ; $i < @lines ; $i++ ) {
        my ( $n, $l ) = @{ $lines[$i] };
        while ( $l =~ /\G(.*?)(\bsub\b|[{}]|\b(?:my|our)\b)/gc ) {
            my ( $before, $tok ) = ( $1, $2 );
            if ( $tok eq 'sub' ) {
                $pending_sub = 1;
                $_->{has_sub} = 1 for @stack;
            }
            elsif ( $tok eq '{' ) {
                push @stack, { sub => $pending_sub, has_sub => 0, decls => [] };
                $pending_sub = 0;
            }
            elsif ( $tok eq '}' ) {
                my $b = pop @stack;
                last unless @stack;
                push @decls, @{ $b->{decls} } if !$b->{sub} && $b->{has_sub};
                $stack[-1]{decls} = $stack[-1]{decls};
            }
            else {
                next if grep { $_->{sub} } @stack;
                next if $before =~ /\b(?:for|foreach)\s*\z/;    # a loop variable
                my $from = pos($l) - length($tok);
                my $stmt = substr( $l, $from );
                my $j    = $i;
                while ( $stmt !~ /;/ && $j + 1 < @lines ) {
                    $j++;
                    $stmt .= ' ' . $lines[$j][1];
                }
                push @{ $stack[-1]{decls} }, [ $n, $tok, $stmt ];
            }
        }
        $pending_sub = 0 if $l =~ /;\s*\z/ && $pending_sub;
    }
    push @decls, @{ $stack[0]{decls} };
    # split each statement into its variables
    my @vars;
    for my $d (@decls) {
        my ( $n, $kind, $stmt ) = @$d;
        # `my ($a, $b)` / `our ($a, @b)` / `my $x` / `our %h`
        my ( $names, $rest );
        if ( $stmt =~ /\A(?:my|our)\s*\(([^)]*)\)\s*(.*)\z/s ) { ( $names, $rest ) = ( $1, $2 ) }
        elsif ( $stmt =~ /\A(?:my|our)\s+([\$\@%]\w+)\s*(.*)\z/s ) { ( $names, $rest ) = ( $1, $2 ) }
        else { next }
        my $list = $stmt =~ /\A(?:my|our)\s*\(/ ? 1 : 0;
        for my $v ( $names =~ /([\$\@%]\w+)/g ) {
            push @vars, { line => $n, kind => $kind, var => $v, stmt => $stmt, rest => $rest, list => $list };
        }
    }
    return @vars;
}

# Is the initialiser made of literals only? "$rest" is what follows the
# declaration. No initialiser is NOT a literal (an empty variable is exactly the
# kind that gets filled later).
sub literal_init {
    my ($rest) = @_;
    return 0 unless $rest =~ /\A=(?!=)\s*(.*?);?\s*\z/s;
    my $rhs = $1;
    return 0 unless length $rhs;
    return 0 if $rhs =~ /\bundef\b/;    # an empty slot, for later
    for my $q (qw(qw qr)) {
        $rhs =~ s{\b$q\s*(?:/(?:\\.|[^/\\])*/|\{(?:\\.|[^{}\\]|\{[^{}]*\})*\}|\((?:\\.|[^()\\]|\([^()]*\))*\)|\[(?:\\.|[^\[\]\\])*\]|\|(?:\\.|[^|\\])*\||!(?:\\.|[^!\\])*!)[a-z]*}{ $q }gs;
    }
    return 0 if $rhs =~ /\bS\b.*\$\w/ && 0;
    # a string that interpolated a variable is not a literal: code_lines made it S
    # and lost that, so interpolation is checked on the raw statement separately.
    $rhs =~ s/\b(?:qw|qr|map|grep|sort|sub|do)\b/ /g;
    $rhs =~ s/\$_\b|\$a\b|\$b\b|\$[0-9]\b//g;
    $rhs =~ s/[=,;(){}\[\]<>:?.+\-*\/x|!&]/ /g;
    $rhs =~ s/\bS\b/ /g;
    $rhs =~ s/\b\d[\d_.]*\b/ /g;
    $rhs =~ s/\b[A-Za-z_]\w*(?=\s*(?:=>|\s|$))/ /g;    # barewords (hash keys, constants)
    return $rhs =~ /\S/ ? 0 : 1;
}

1;
