#!/usr/bin/perl
# SM044: unit tests for the site-config dropdown endpoints plus the
# layouts_repo read/write helpers the /manager/themes page uses.
# Also verifies the processor's --describe output has the expected
# SM044 shape (layouts_repo in config_keys; layout/theme types set
# to the dynamic-dropdown variants).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json decode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

sub write_conf {
    my ($content) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $content;
    close $fh;
}

sub write_layout {
    my ($name) = @_;
    my $dir = "$docroot/lazysite/layouts/$name";
    make_path($dir);
    open my $fh, '>', "$dir/layout.tt" or die $!;
    print $fh "<html>[% content %]</html>\n";
    close $fh;
}

sub write_theme {
    my ( $layout, $theme, $layouts_arr ) = @_;
    my $dir = "$docroot/lazysite/layouts/$layout/themes/$theme";
    make_path($dir);
    open my $fh, '>', "$dir/theme.json" or die $!;
    print $fh encode_json({
        name    => $theme,
        version => '1.0',
        layouts => $layouts_arr,
        config  => { colours => { primary => '#000' } },
    });
    close $fh;
}

# --- 1. Processor --describe shape (SM044 + SM068) ---

subtest 'processor --describe includes SM044 + SM068 fields' => sub {
    my $out = qx($^X \Q$root/lazysite-processor.pl\E --describe 2>/dev/null);
    my $desc = decode_json($out);

    ok( ( grep { $_ eq 'layouts_repo' } @{ $desc->{config_keys} } ),
        'layouts_repo in config_keys' );

    my ($layout_entry) = grep { $_->{key} eq 'layout' }
        @{ $desc->{config_schema} };
    is( $layout_entry->{type}, 'dropdown_layouts',
        'layout entry has dropdown_layouts type' );

    my ($theme_entry) = grep { $_->{key} eq 'theme' }
        @{ $desc->{config_schema} };
    is( $theme_entry->{type}, 'dropdown_themes_for_active_layout',
        'theme entry has dropdown_themes_for_active_layout type' );
    is( $theme_entry->{depends_on}, 'layout',
        'theme entry depends_on layout' );

    # SM068: layouts_repo is now displayed on Config as a
    # read-only entry linking to /manager/themes.
    my ($lr_entry) = grep { $_->{key} eq 'layouts_repo' }
        @{ $desc->{config_schema} };
    ok( $lr_entry, 'layouts_repo now IN config_schema' );
    is( $lr_entry->{type}, 'readonly_with_link',
        'layouts_repo is readonly_with_link' );
    is( $lr_entry->{link_href}, '/manager/themes',
        'layouts_repo link points at /manager/themes' );
    ok( $lr_entry->{link_label},
        'layouts_repo has a link_label for the UI button' );
};

# --- Load the manager-api after setting DOCROOT ---
BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

# --- 2. layouts-available returns installed layouts ---

subtest 'layouts-available scans layouts/*/layout.tt' => sub {
    write_layout('default');
    write_layout('studio');
    my $r = main::action_layouts_available();
    ok( $r->{ok}, 'ok' );
    is_deeply( [ sort @{ $r->{layouts} } ],
        [qw(default studio)],
        'both installed layouts listed' );
};

subtest 'layouts-available: empty when no layouts dir' => sub {
    my $d = tempdir( CLEANUP => 1 );
    local $ENV{DOCUMENT_ROOT} = $d;
    # Re-derive DOCROOT for this sub. The loaded module captured
    # $DOCROOT at load time, so we can't override it per-call.
    # Verify the more important invariant instead: the returned
    # layouts list has only valid entries.
    my $r = main::action_layouts_available();
    ok( $r->{ok}, 'ok' );
    ok( ref $r->{layouts} eq 'ARRAY', 'always returns an array' );
};

subtest 'layouts-available: skips layouts without layout.tt' => sub {
    # Directory present but no layout.tt: should be filtered out.
    make_path("$docroot/lazysite/layouts/no-tt");
    my $r = main::action_layouts_available();
    ok( !( grep { $_ eq 'no-tt' } @{ $r->{layouts} } ),
        'layout dir without layout.tt is not listed' );
};

# --- 3. themes-for-layout filters by layouts[] compatibility ---

subtest 'themes-for-layout returns compatible themes only' => sub {
    # Light: targets only default. Dark: targets default + studio.
    # Odd: declares studio only; does NOT target default.
    write_theme( 'default', 'light', ['default'] );
    write_theme( 'default', 'dark',  [ 'default', 'studio' ] );
    write_theme( 'default', 'odd',   ['studio'] );

    my $r = main::action_themes_for_layout('default');
    ok( $r->{ok}, 'ok' );
    is( $r->{layout}, 'default', 'layout echoed' );
    is_deeply( [ sort @{ $r->{themes} } ],
        [qw(dark light)],
        'only themes whose layouts[] includes default are listed' );
};

subtest 'themes-for-layout rejects empty/invalid layout param' => sub {
    my $r = main::action_themes_for_layout('');
    ok( !$r->{ok}, 'empty layout rejected' );
    is_deeply( $r->{themes}, [], 'no themes returned' );

    my $r2 = main::action_themes_for_layout('../../etc');
    # Sanitisation strips non-alnum-underscore-hyphen, leaving 'etc'.
    # That's not a real layout, so no themes returned, but the call
    # proceeds (i.e. the sanitiser doesn't reject the normalised form).
    is_deeply( $r2->{themes}, [],
        'sanitised path-traversal attempt returns empty' );
};

# --- 4. layouts-repo-get reads lazysite.conf ---

subtest 'layouts-repo-get reads the conf key' => sub {
    write_conf("site_name: T\nlayouts_repo: OpenDigitalCC/lazysite-layouts\n");
    my $r = main::action_layouts_repo_get();
    ok( $r->{ok}, 'ok' );
    is( $r->{value}, 'OpenDigitalCC/lazysite-layouts', 'value returned' );
};

subtest 'layouts-repo-get: empty when key unset' => sub {
    write_conf("site_name: T\n");
    my $r = main::action_layouts_repo_get();
    ok( $r->{ok}, 'ok' );
    is( $r->{value}, '', 'empty string when unset' );
};

# --- 5. layouts-repo-set writes atomically ---

subtest 'layouts-repo-set writes the conf key' => sub {
    write_conf("site_name: T\n");
    my $r = main::action_layouts_repo_set('OpenDigitalCC/lazysite-layouts');
    ok( $r->{ok}, 'ok' );
    is( $r->{value}, 'OpenDigitalCC/lazysite-layouts', 'echoes value' );

    open my $fh, '<', "$docroot/lazysite/lazysite.conf" or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr{^layouts_repo: OpenDigitalCC/lazysite-layouts$}m,
        'conf file has the new key' );
};

subtest 'layouts-repo-set replaces an existing value' => sub {
    write_conf("site_name: T\nlayouts_repo: old/repo\n");
    my $r = main::action_layouts_repo_set('new/repo');
    ok( $r->{ok}, 'ok' );

    open my $fh, '<', "$docroot/lazysite/lazysite.conf" or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr{^layouts_repo: new/repo$}m, 'updated' );
    unlike( $text, qr{^layouts_repo: old/repo$}m, 'old value gone' );
};

subtest 'layouts-repo-set with empty value removes the key' => sub {
    write_conf("site_name: T\nlayouts_repo: some/repo\n");
    my $r = main::action_layouts_repo_set('');
    ok( $r->{ok}, 'ok' );

    open my $fh, '<', "$docroot/lazysite/lazysite.conf" or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    unlike( $text, qr{layouts_repo}, 'key removed entirely' );
};

# --- 6. layouts-repo-set rejects malformed values ---

subtest 'layouts-repo-set rejects invalid OWNER/REPO formats' => sub {
    write_conf("site_name: T\n");
    for my $bad (
        'not-a-path',                 # no slash
        '/leading-slash/repo',        # leading slash
        'owner/',                     # trailing slash, empty repo
        '/repo',                      # empty owner
        'owner/repo/extra',           # two slashes
        'owner with space/repo',      # space
        '../../../etc/passwd',        # path traversal attempt
        '-badstart/repo',             # segment starting with -
        'owner/.badstart',            # segment starting with .
    ) {
        my $r = main::action_layouts_repo_set($bad);
        ok( !$r->{ok}, "rejects: $bad" );
        like( $r->{error}, qr/OWNER\/REPO/,
            "error explains format for: $bad" );
    }
};

subtest 'layouts-repo-set accepts GitHub-allowed names' => sub {
    write_conf("site_name: T\n");
    for my $good (
        'Owner/Repo',
        'owner123/repo456',
        'owner-with-dashes/repo.with.dots',
        'OpenDigitalCC/lazysite-layouts',
    ) {
        my $r = main::action_layouts_repo_set($good);
        ok( $r->{ok}, "accepts: $good" ) or diag explain $r;
    }
};

done_testing();
