#!/usr/bin/perl
# n562: A TEST ACCOUNT HAS A PASSWORD THE POLICY TAKES.
#
# SM1041 set the shortest password any door accepts at 12 characters. Five tests
# still made their account with `pw123456789` (11): the users tool refused it,
# the test threw the refusal away (2>/dev/null), and every assertion after it
# ran on a site with no such account - t/integration/51 and 65 on an unsecured
# site as any name at all - and passed. Nothing failed, so nothing said so.
#
# This refuses the shape: a password LITERAL under 12 characters handed to the
# users tool's account verbs in t/ - `add`, `passwd`, `account-create` and
# `setup-sysop --user NAME PW`, in a command line or an argument list. An empty
# password is a passwordless (token-only) account, which is legitimate. A
# password in a variable is not read. The tests that set password_min_length
# themselves pass their passwords in variables, so a lower floor of their own
# is not a reason for an exception here.
#
# Basic credentials are NOT checked: under 12 characters in t/ they are token
# secrets (lzs_...) or a password sent wrong on purpose to get a 401, and a
# length rule cannot tell either from a stale password. An account made with a
# short one is refused at creation, which is what this catches.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $MIN = 12;

# Does this file drive the users tool? The verbs are common words (`git add`,
# a hosting panel's `add user`), so a line is read only in a file that does.
sub drives_users_tool {
    my ($src) = @_;
    return $src =~ /lazysite-users|->users\(|\busers\(|dav_users_tool|ManagerSession/ ? 1 : 0;
}

# The short password literals in one source text, as "line: verb password".
sub short_passwords {
    my ($src) = @_;
    return () unless drives_users_tool($src);
    my $q   = qr/['"]?/;
    my $sep = qr/(?:['"]?\s*,\s*['"]?|['"]?\s+['"]?)/;
    my $arg = qr/(?>[^\s'",(){}\[\]]+)/;
    my @hits;
    my $n = 0;
    for my $l ( split /\n/, $src ) {
        $n++;
        next if $l =~ /^\s*#/;
        next if $l =~ /\b(?:w?git|run_tool)\s*\(/;
        my @pw;
        # add USER PW: a command line (--docroot DIR add ...) or a list ('add', ...)
        push @pw, [ $1, $2 ] while $l =~ /--docroot\s+\S+\s+(add|passwd|account-create)\s+$arg\s+($arg)/g;
        push @pw, [ $1, $2 ] while $l =~ /['"](add|passwd|account-create)['"]\s*,\s*['"][^'"]+['"]\s*,\s*['"]([^'"]*)['"]/g;
        push @pw, [ 'setup-sysop', $1 ] while $l =~ /setup-sysop$sep--user$sep$arg$sep($arg)/g;
        for my $h (@pw) {
            my ( $verb, $p ) = @$h;
            next if $p =~ /\A[-\$\@\d]/ && $p !~ /\A\d{4,}/; # a flag, a variable, a redirect
            next unless length $p && length $p < $MIN;
            push @hits, "$n: $verb $p";
        }
    }
    return @hits;
}

subtest 'the check finds the shapes it is for' => sub {
    my $u = "my \$users = 'tools/lazysite-users.pl';\n";
    is_deeply( [ short_passwords( $u . "qx(\$^X \\Q\$users\\E --docroot \\Q\$d\\E add zz9 pw123456789 2>/dev/null);\n" ) ],
        ['2: add pw123456789'], 'a command-line add' );
    is_deeply( [ short_passwords( $u . "qx(\$^X \\Q\$users\\E --docroot \\Q\$d\\E setup-sysop --user sjm pw123456789 2>&1);\n" ) ],
        ['2: setup-sysop pw123456789'], 'a command-line setup-sysop' );
    is_deeply( [ short_passwords( $u . "\$ms->users( 'add', 'bob', 'secret' );\n" ) ], ['2: add secret'], 'a list add' );
    is_deeply( [ short_passwords( $u . "\$ms->users( 'setup-sysop', '--user', 'ada', 'hunter2' );\n" ) ],
        ['2: setup-sysop hunter2'], 'a list setup-sysop' );
    is_deeply( [ short_passwords( $u . "run_cli( 'passwd', 'bob', 'short' );\n" ) ], ['2: passwd short'], 'a passwd' );
};

subtest 'and passes what it is not for' => sub {
    my $u = "my \$users = 'tools/lazysite-users.pl';\n";
    is_deeply( [ short_passwords( $u . "\$ms->users( 'add', 'bob', 'pw123456789-long-enough' );\n" ) ], [], 'a long password' );
    is_deeply( [ short_passwords( $u . "cli( \$d, 'add', 'tokonly', '' );\n" ) ], [], 'a passwordless account' );
    is_deeply( [ short_passwords( $u . "\$ms->users( 'setup-sysop', '--user', 'ada' );\n" ) ], [], 'a setup-sysop with no password' );
    is_deeply( [ short_passwords( $u . "cli( \$l, 'setup-sysop', '--user', 'root2', '--link' );\n" ) ], [], 'a setup link' );
    is_deeply( [ short_passwords( $u . "cli( \$d, 'add', 'bob', \$pw );\n" ) ], [], 'a password in a variable' );
    is_deeply( [ short_passwords( $u . "git( \$d, 'add', 'a.txt', 'b.txt' );\n" ) ], [], 'git add' );
    is_deeply( [ short_passwords("( \$rc, \$out ) = run( {}, 'add', 'user', 'bad domain!' );\n") ], [],
        'a file that does not drive the users tool' );
};

my $root = repo_root();
my @files;
find( sub { push @files, $File::Find::name if /\.(?:t|pm)\z/ && $File::Find::name !~ m{/t/lint/260-} }, "$root/t" );
cmp_ok( scalar @files, '>', 500, 'found the tests to read' );

my @bad;
for my $f ( sort @files ) {
    open my $fh, '<', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    push @bad, map { "$rel:$_" } short_passwords($src);
}
is_deeply( \@bad, [], "no test makes an account with a password under $MIN characters" )
    or diag( join( "\n", @bad, '' )
        . 'The users tool refuses it (SM1041), and a test that throws the refusal away '
        . 'tests a site without the account. Use one of 12 or more, and assert the account was made.' );

done_testing();
