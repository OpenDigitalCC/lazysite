#!/usr/bin/perl
# SM944: THE PROCESSOR'S PARTS STAY PARTS.
#
# The processor is being split by area into files under lazysite-processor/ that
# it requires by absolute path from beside itself. That keeps ADR 0001's render
# path - no Lazysite:: module, no lib tree, no module load on a cache hit - only
# while every part keeps four promises, and each is one a later edit could break
# without any test noticing:
#
#   1. it is package main, so a move is a pure move and nothing is imported;
#   2. it loads nothing at compile time (strict and warnings only) - a `use`
#      here is a load on every request, which is the trade ADR 0001 refused;
#   3. the script's loader names exactly the files that exist, so a part is
#      never shipped unloaded nor loaded from somewhere it is not;
#   4. no sub is defined twice across the script and its parts, so a move
#      that left its original behind (one silently wins) fails here;
#   5. it names none of the script's file-scope `my` variables. A part is a
#      separate file and cannot see them: under strict a bare name fails to
#      compile, but `our $X` or `$main::X` compiles and reads a DIFFERENT,
#      empty variable. Shared state is declared `our` in the script (SM944 S2)
#      and a part aliases it with a bare `our ( ... );`; a part keeps strict
#      vars on so every other name it uses must be its own. Its file-scope
#      code, the alias aside, reads none of the script's variables: a
#      part is compiled and run inside the loader's BEGIN, before the script's
#      own initialisations have executed, so it would see them empty.
#
# Checked by a source scan, not PPI (not a dependency here) or B::Deparse (which
# cannot say where a variable was declared): the script's declarations are the
# column-0 `my`/`our` lines, which is the form every one of them takes.
#
# And each starts with the index a reader needs first: HOLDS and OWNS lines.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $dir  = "$root/lazysite-processor";

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

opendir my $dh, $dir or die "$dir: $!";
my @parts = sort grep { !/^\./ && -f "$dir/$_" } readdir $dh;
closedir $dh;
ok( scalar @parts, 'the processor has parts' );

my $proc = slurp("$root/lazysite-processor.pl");

subtest 'the loader names exactly the parts that exist, by path' => sub {
    my ($list) = $proc =~ /for my \$part \(qw\(([^)]*)\)\)/;
    ok( defined $list, 'the loader is found' ) or return;
    is_deeply( [ sort split ' ', $list ], \@parts,
        'every part is loaded, and nothing is loaded that is not a part' );
    like( $proc, qr/dirname\(\s*realpath\(__FILE__\)\s*\)\s*\.\s*'\/lazysite-processor'/,
        'the parts are found from where the script really is, not through @INC' );
};

my %defined_in;
push @{ $defined_in{$_} }, 'lazysite-processor.pl' for $proc =~ /^sub (\w+)/mg;

# The script's file-scope variables: name (with sigil) => 'my' | 'our'.
my %scope;
for my $line ( split /\n/, $proc ) {
    next unless $line =~ /^(my|our)\s*(\([^)]*\)|[\$\@%]\w+)/;
    my $kind = $1;
    $scope{$_} = $kind for $2 =~ /([\$\@%]\w+)/g;
}
my @script_my = sort grep { $scope{$_} eq 'my' } keys %scope;
cmp_ok( scalar( grep { $scope{$_} eq 'our' } keys %scope ), '>', 0,
    'the script declares shared state as our' );
cmp_ok( scalar @script_my, '>', 0, 'and its own state as my (the scan sees both)' );

# Every way code can name a variable: the plain name, an element or slice of an
# aggregate, an optional main:: or :: qualifier, and the ${NAME} form.
sub names_var {
    my ( $code, $var ) = @_;
    my ( $sig, $nm ) = ( substr( $var, 0, 1 ), substr( $var, 1 ) );
    my $q = qr/(?:main)?::/;
    my $re =
        $sig eq '$' ? qr/\$\{?\s*(?:$q)?\Q$nm\E\b(?!\s*[\[\{])/
      : $sig eq '@' ? qr/(?:\@(?:$q)?\Q$nm\E\b(?!\s*\{)|\$(?:$q)?\Q$nm\E\s*\[|\$#\{?(?:$q)?\Q$nm\E\b)/
      :               qr/(?:%(?:$q)?\Q$nm\E\b|[\$\@](?:$q)?\Q$nm\E\s*\{)/;
    return $code =~ $re;
}

# Lines of code outside every sub body: what runs when the part is required.
sub file_scope_code {
    my ($code) = @_;
    my ( @out, $in );
    for my $l ( split /\n/, $code ) {
        if ( !$in && $l =~ /^sub \w+/ ) { $in = $l !~ /\}\s*$/; next }
        if ( $in && $l =~ /^\}/ ) { $in = 0; next }
        push @out, $l unless $in;
    }
    return join "\n", @out;
}

for my $p (@parts) {
    subtest $p => sub {
        like( $p, qr/\A[a-z][a-z0-9-]*\.pm\z/,
            'a .pm, so the installer leaves it 0644 and no web server runs it' );
        my $s = slurp("$dir/$p");
        like( $s, qr/\Apackage main;\n/, 'package main, first line' );
        like( $s, qr/^# HOLDS /m, 'the index says what it holds' );
        like( $s, qr/^# OWNS /m,  'the index says what it owns' );
        my @use = grep { $_ ne 'strict' && $_ ne 'warnings' } $s =~ /^\s*use\s+([\w:]+)/mg;
        is_deeply( \@use, [], 'loads nothing at compile time (ADR 0001)' );
        ( my $code = $s ) =~ s/^\s*#.*\n//mg;
        unlike( $code, qr/\@INC/, 'touches no @INC' );
        push @{ $defined_in{$_} }, $p for $s =~ /^sub (\w+)/mg;

        $code =~ s/(?<=\s)#[^\n]*//g;    # trailing comments
        unlike( $code, qr/\bno\s+strict\b/,
            'keeps strict on, so a name it does not declare fails to compile' );
        my %own_my = map { $_ => 1 }
          map { /([\$\@%]\w+)/g } $code =~ /\bmy\s*(\([^)]*\)|[\$\@%]\w+)/g;
        my @named;
        for my $v (@script_my) {
            ( my $bare = $code ) =~ s/\b(?:my|our)\s*(?:\([^)]*\)|[\$\@%]\w+)//g;
            my $qualified = $code =~ /[\$\@%#]\{?\s*(?:main)?::\Q${\ substr( $v, 1 )}\E\b/;
            my $declared  = $code =~ /\bour\s*(?:\([^)]*\Q$v\E\b[^)]*\)|\Q$v\E\b)/;
            push @named, $v
              if $qualified || $declared || ( !$own_my{$v} && names_var( $bare, $v ) );
        }
        is_deeply( \@named, [], "names none of the script's own (my) variables" )
          or diag("declare it `our` in lazysite-processor.pl (SM944 S2): @named");
        # A bare `our ( ... );` is how a part reaches shared state: an alias,
        # not a read. With an initialiser it would be a write, and stays flagged.
        ( my $top = file_scope_code($code) ) =~
          s/^\s*our\s*(?:\([^)]*\)|[\$\@%]\w+)\s*;//mg;
        my @read = grep { !$own_my{$_} && names_var( $top, $_ ) } sort keys %scope;
        is_deeply( \@read, [], "its file-scope code reads none of the script's variables" )
          or diag("they are still empty when the loader's BEGIN runs it: @read");
    };
}

my @twice = sort grep { @{ $defined_in{$_} } > 1 } keys %defined_in;
is_deeply( \@twice, [], 'no sub is defined in two places' )
    or diag( join "\n", map { "  $_: @{ $defined_in{$_} }" } @twice );

done_testing();
