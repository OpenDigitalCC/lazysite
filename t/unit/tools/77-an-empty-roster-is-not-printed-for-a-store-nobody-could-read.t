#!/usr/bin/perl
# SM800. SM770 removed the stat guards from the auth MODULES and left the
# display question open: the readers answer empty for a store they could not
# read, which is right for a GATE (empty means deny, which fails closed) and
# wrong for anything a person reads, where an empty table is a statement about
# the site.
#
# Building it found the cause rather than the symptom. The tool that WRITES the
# store and holds its two primary readers was not in Lazysite::Stores, so
# t/lint/121 - written under SM770 to catch exactly this - had never looked at
# it, and both readers still carried the guard.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper       qw(repo_root site_tempdir);
use Lazysite::Stores qw(store_for);

my $root = repo_root();

# The durable half, asserted first because it is what stops the next one.
subtest 'the catalogue names the tool that owns the store' => sub {
    my $auth = store_for('auth');
    ok( $auth && $auth->{store}, 'auth is a store' ) or return;
    ok( ( grep { $_ eq 'tools/lazysite-users.pl' } @{ $auth->{modules} } ),
        'and the tool that writes it is one of its modules' )
        or diag( 'The lint that catches a stat guard in front of a store read '
            . 'only looks at the modules the catalogue names. This file holds '
            . 'read_users and read_groups.' );
};

# SM685: THE READERS MOVED, and the assertion followed them rather than being
# deleted. read_users and read_groups now live in Lazysite::Auth::Verify, where
# the CGIs reach them without compiling the tool, and both go through one
# opener - so the guarantee SM800 established is asserted once, at the place
# that could lose it. The tool's own subs are checked separately: they must
# still DELEGATE, because a reader reintroduced there would be a second
# implementation and the first thing it would grow back is the stat guard.
subtest 'the one reader does not stat before it opens' => sub {
    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Auth/Verify.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($body) = $src =~ /(sub _read_colon_file \{.*?\n\})/s;
    ok( $body, '_read_colon_file was found' ) or return;
    unlike( $body, qr/unless -[fe] /,
        'it does not stat before opening - a stat the process may not make '
            . 'fails like an open it may not make' );
    like( $body, qr/cannot_read/, 'it reports through cannot_read' );
    like( $body, qr/STORE_READABLE = 0/,
        'it records that it could not read, because the hash has nowhere to '
            . 'carry it' );
    like( $body, qr/\$!\{ENOENT\}/,
        'it treats an absent store as ordinary, not as a fault' );

    my $tool = do {
        open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
        local $/;
        <$fh>;
    };
    for my $sub (qw(read_users read_groups)) {
        my ($t) = $tool =~ /(sub \Q$sub\E \{.*?\n\})/s;
        ok( $t, "the tool's $sub was found" ) or next;
        like( $t, qr/Lazysite::Auth::Verify::\Q$sub\E/,
            "the tool's $sub delegates rather than reading the store itself" );
    }
};

# The behaviour the release manager asked for.
subtest 'the listing says which, rather than printing a roster of none' => sub {
    plan skip_all => 'root reads every file; this needs an unprivileged user' if $> == 0;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/auth/users" or die $!;
    print {$fh} "alice:x\nbob:y\n";
    close $fh;

    my $tool = "$root/tools/lazysite-users.pl";
    my $run  = sub {
        my $out = qx{$^X \Q$tool\E --docroot \Q$d\E list 2>/dev/null};
        return $out // '';
    };

    like( $run->(), qr/alice/, 'a readable store lists its accounts' );

    chmod 0000, "$d/lazysite/auth/users";
    my $unreadable = !-r "$d/lazysite/auth/users";
    unless ($unreadable) {
        chmod 0644, "$d/lazysite/auth/users";
        plan skip_all => 'this filesystem ignores the file mode';
    }
    my $out = $run->();
    chmod 0644, "$d/lazysite/auth/users";

    unlike( $out, qr/^No users\.$/m,
        'an unreadable store is NOT reported as a site with no accounts' );
    like( $out, qr/could not be read/,
        'it says the store could not be read' );
    like( $out, qr/permissions/,
        'and names the thing to fix, so the operator looks at the right half of the day' );
};

subtest 'the answer carries the fourth state to every caller' => sub {
    my $src = do {
        open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/\$result->\{store_readable\}/,
        'store_readable rides the --api answer' );
    like( $src, qr/if ref \$result eq 'HASH' && \$result->\{ok\}/,
        'set once where the answer is encoded - a flag each branch must '
            . 'remember is a flag some branch will not' );

    my $page = do {
        open my $fh, '<', "$root/starter/manager/users.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $page, qr/var STORE_READABLE = null;/,
        'the page starts at null - "nobody has told us" is not "the store is fine"' );
    like( $page, qr/STORE_READABLE === false/,
        'and withholds the roster only on a NEGATIVE answer' );
    like( $page, qr/could not be read/, 'saying so where the table would have been' );
};

done_testing;
