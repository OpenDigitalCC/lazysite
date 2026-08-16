#!/usr/bin/perl
# SM321: the installer's idea of the private store must match the engine's.
#
# WHY THE FACT EXISTS TWICE. `Lazysite::Private::private_root` owns where the
# store lives. `install.pl` cannot call it: the installer is core-Perl-only by
# design, because it must run before - and independently of - the engine it
# installs. So it carries its own construction, and this pins the two together.
#
# That is the same treatment t/lint/45 gives ADR 0008's frozen fields and
# t/lint/36 gives a reference table: where a fact must exist twice, the second
# copy is asserted against the first rather than trusted.
#
# WHAT IT PROTECTS. The store is a SIBLING of the docroot, not a child. Every
# defect in this area came from something getting that wrong or not knowing it at
# all: SM270's docroot repair never reached it, SM313 had to add bespoke creation
# code because nothing declared it, and SM323 was two code paths racing to create
# it with different ownership because there was no single description of what it
# should be. A drift here would silently reintroduce all of that - the installer
# would provision one directory and the engine would use another.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(repo_root);
use Lazysite::Private ();

my $root = repo_root();

subtest 'the installer and the engine agree on the path' => sub {
    # The installer's OWN sub, evaluated - not a regex over its source, because
    # what matters is the value it produces. `do install.pl` is not an option:
    # the installer has a main body and would run it.
    my $src = do {
        open my $fh, '<', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /(\nsub _private_store_for \{.*?\n\}\n)/s;
    ok( $sub, 'install.pl carries its own store-path construction' ) or return;

    my $pkg = 'InstallerUnderTest';
    eval "package $pkg; use File::Basename qw(basename dirname); $sub 1;"
        or do { fail("could not evaluate it: $@"); return };

    for my $doc (
        '/home/alice/web/example.com/public_html',
        '/srv/sites/one',
        '/var/www/html/',    # trailing slash
        '/home/b/web/x.y.z/public_html',
        )
    {
        my $engine    = Lazysite::Private::private_root($doc);
        my $installer = InstallerUnderTest::_private_store_for($doc);
        is( $installer, $engine,
            "agree for $doc" )
            or diag( "engine:    $engine\n"
                . "installer: $installer\n"
                . "The installer would provision one directory and the engine "
                . "would use another." );
    }
};

subtest 'and it is declared as a runtime path' => sub {
    # The declaration is what makes install provision it and check repair it,
    # which is what removes the race in SM323 - no code path has to decide
    # anything, because the shape is stated once.
    my $cfg = "$root/dist/config/classification.json";
    ok( -f $cfg, 'the classification config is present' ) or return;

    require JSON::PP;
    open my $fh, '<', $cfg or die $!;
    my $json = do { local $/; <$fh> };
    close $fh;
    my $c = JSON::PP::decode_json($json);

    my ($store) = grep { ( $_->{path} // '' ) eq '{PRIVATE_STORE}' }
        @{ $c->{runtime_paths} || [] };
    ok( $store, 'the private store is declared in runtime_paths' )
        or diag( 'It was the only runtime directory nobody declared, which is '
            . 'what let two code paths create it with different ownership.' );
    return unless $store;

    is( $store->{mode}, '2770',
        'group-writable by the CGI, setgid, nothing for the world' );
    is_deeply( [ sort @{ $store->{applied_by} } ], [ 'check', 'install' ],
        'install provisions it and check repairs it' );
    is( $store->{on_upgrade}, 'repair',
        'and an upgrade repairs it, so an existing site is corrected' );

    # Either field - the point is that the geometry is written down where a
    # reader of the declaration will meet it, not which key holds it.
    my $prose = join ' ', ( $store->{purpose} // '' ), ( $store->{why} // '' );
    like( $prose, qr/sibling/i,
        'the declaration records that it is a sibling, not a child' )
        or diag( 'Every defect in this area came from not knowing that. A '
            . 'reader who assumes "child" will write another docroot repair '
            . 'that never reaches it.' );
};

subtest 'the placeholder actually resolves' => sub {
    # A declared path nothing substitutes is worse than no declaration: install
    # would try to create a directory literally named "{PRIVATE_STORE}".
    my $src = do {
        open my $fh, '<', "$root/install.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/PRIVATE_STORE\s*=>\s*_private_store_for/,
        'placeholders() supplies PRIVATE_STORE' );

    my ($sub) = $src =~ /(\nsub _private_store_for \{.*?\n\}\n)/s;
    eval "package StoreResolveCheck; use File::Basename qw(basename dirname); $sub 1;";
    my $doc = tempdir( CLEANUP => 1 ) . '/public_html';
    my $got = StoreResolveCheck::_private_store_for($doc);
    unlike( $got, qr/\{|\}/, 'and it resolves to a real path, not a template' );
    like( $got, qr/-lazysite-private\z/, 'named as the engine names it' );
};

done_testing();
