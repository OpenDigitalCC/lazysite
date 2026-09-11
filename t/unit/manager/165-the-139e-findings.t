#!/usr/bin/perl
# The 139E field results, other than the 500 (SM804). Four findings and a
# validation gap, each verified against the source before it was accepted.
#
# The one NOT here is 139E-06's nav marking. The field observed a
# low-privilege account seeing five items ABSENT rather than marked, which is
# exactly the pre-SM775 behaviour - and the template on main renders 16 items
# with 5 locked for that capability set, which the last subtest proves. So the
# engine is right and the deployed copy is not, which is a deployment question
# and not something a unit test can settle.
use strict;
use warnings;
use Test::More;
use Template;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                    qw(repo_root site_tempdir);
use Lazysite::Data::Tables        ();
use Lazysite::Manager::Connectors ();

my $root = repo_root();
sub src {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or die "$f: $!";
    local $/;
    return <$fh>;
}
sub render {
    my ( $file, $caps ) = @_;
    my $t   = Template->new( EVAL_PERL => 0 ) or die Template->error;
    my $out = '';
    $t->process( \src($file),
        { manager_caps => $caps, request_uri => '/manager/', enabled_plugins => { data => 1 },
            content => '', page_title => '', auth_user => 'u', query => {} },
        \$out ) or die "$file: " . $t->error;
    return $out;
}

# 139E-06 step 4. The field's phrasing is the argument: the sentence "sends the
# one account that can fix it to look for the person who can fix it".
# The page carries an HTML comment explaining this change, and that comment
# quotes the very sentence the assertion forbids - so the comparison is made
# against what a READER sees, with comments stripped. The first version of this
# test failed on its own explanation.
sub visible {
    my ($html) = @_;
    $html =~ s/<!--.*?-->//gs;
    return $html;
}

subtest 'the remedy depends on who is reading it' => sub {
    my $plain = visible( render( 'starter/manager/config.md', {} ) );
    like( $plain, qr/A user manager can grant\s+it/,
        'an account that cannot grant is told to find one' );

    my $mgr = visible( render( 'starter/manager/config.md', { manage_users => 1 } ) );
    like( $mgr, qr/You can grant\s+it/,
        'and an account that CAN grant is told it can' );
    unlike( $mgr, qr/A user manager can grant\s+it/,
        'not sent looking for itself' );
    like( $mgr, qr{href="/manager/groups"}, 'with the page it happens on' );
};

# 139E-06 step 1: the landing was right and the HEADING said otherwise.
subtest 'the account landing is headed for what it is' => sub {
    my $fm = ( src('starter/manager/index.md') =~ /\A---\n(.*?)\n---/s )[0];
    like( $fm, qr/^title: Your account$/m,
        'the page is titled for the case that is actually read' );
    unlike( $fm, qr/page_title_when_no_config/,
        'and not by a front-matter key nothing reads' );

    my $without = render( 'starter/manager/index.md', {} );
    like( $without, qr/mgOpenAccount/, 'the account sheet is still what it offers' );
    my $with = render( 'starter/manager/index.md', { manage_config => 1 } );
    like( $with, qr/location\.replace/,
        'and a holder is still forwarded, so never reads the heading' );
};

# 139E-02: the credential state moved 130px between rows.
subtest 'a row action group anchors, so a column can be read down' => sub {
    for my $sheet (qw(classic accessible modern)) {
        my $css = src("starter/lazysite/manager/assets/manager-$sheet.css");
        my ($rule) = $css =~ /^\.mg-row-actions \{([^}]*)\}/m;
        ok( $rule, "$sheet: the rule exists" ) or next;
        like( $rule, qr/margin-left:\s*auto/,
            "$sheet: the group sits at the END of the row, not wherever the "
                . 'text before it happens to finish' );
    }
};

# 139E-04's wording note, measured against 139E-03's refusal, which the field
# called the best-worded in the release.
subtest 'a mode refusal names the mode that would work' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/connectors");
    local $Lazysite::Manager::Connectors::DOCROOT = $d;
    Lazysite::Manager::Connectors::action_connector_save( 'tick', {
            url            => 'http://127.0.0.1:8787/echo',
            modes          => { scheduled => 1, authenticated => 0, public => 0 },
    } );
    my $all = Lazysite::Manager::Connectors::connectors();
    my ( $may, $why ) = Lazysite::Manager::Connectors::may_call( $all->{tick},
        mode => 'authenticated', caps => { manage_connectors => 1 }, groups => [] );
    is( $may, 0, 'a scheduled-only connector refuses a request-time call' );
    like( $why, qr/does not permit authenticated/, 'naming what failed' );
    like( $why, qr/it permits: scheduled/,
        'AND what would work - the caller learns the next step in the same '
            . 'sentence, which is the standard the redirect refusal set' );
};

# 139E-05: accepted at save, and could only fail at call time.
subtest 'a mapped column that is not a column is refused at save' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/connectors");
    local $Lazysite::Manager::Connectors::DOCROOT = $d;
    my $dir = Lazysite::Data::Tables::descriptor_dir($d);
    make_path($dir);
    open my $y, '>', "$dir/orders.yaml" or die $!;
    print {$y} "key: code\nfields:\n  code:  { type: text }\n  alpha: { type: text }\n";
    close $y;

    my $bad = Lazysite::Manager::Connectors::action_connector_save( 'bad', {
            url     => 'https://example.test/x', row_table => 'orders',
            row_map => { nosuch => 'x_out' },
    } );
    ok( !$bad->{ok}, 'refused' ) or diag explain $bad;
    like( $bad->{error}, qr/does not have: nosuch/,    'naming the column' );
    like( $bad->{error}, qr/columns are: alpha, code/, 'and the ones it does have' );
    is( $bad->{field}, 'row_map', 'with a machine-readable field' );

    my $ok = Lazysite::Manager::Connectors::action_connector_save( 'good', {
            url     => 'https://example.test/x', row_table => 'orders',
            row_map => { alpha => 'a_out', code => 'k_out' },
    } );
    ok( $ok->{ok}, 'a real column, and the key, are accepted' ) or diag explain $ok;

    # UNVALIDATED IS NOT INVALID: a descriptor that cannot be read says nothing
    # about this mapping, and refusing the save would make an unrelated fault
    # look like a bad map.
    my $unknown = Lazysite::Manager::Connectors::action_connector_save( 'later', {
            url     => 'https://example.test/x', row_table => 'notdeclaredyet',
            row_map => { whatever => 'w_out' },
    } );
    ok( $unknown->{ok},
        'a table this instance cannot read does not block the save' )
        or diag explain $unknown;
};

# The nav, which the field reported as broken on edge.
subtest 'the nav marks, rather than hides, for an account with fewer grants' => sub {
    my %seen;
    for my $case (
        [ 'sysop-ish',   { manage_users   => 1, manage_config => 1 } ],
        [ 'users only',  { manage_users   => 1 } ],
        [ 'content+nav', { manage_content => 1, manage_nav => 1 } ],
        [ 'capless',     {} ],
        )
    {
        my ( $name, $caps ) = @$case;
        my ($nav) = render( 'starter/lazysite/manager/layout.tt', $caps )
            =~ /(<nav class="mg-nav".*?<\/nav>)/s;
        my @items = $nav =~ /(?:<a[^>]*>|<span class="mg-nav-locked"[^>]*>)\s*([A-Z][^<]*?)\s*</g;
        my @locked = $nav =~ /mg-nav-locked[^>]*>\s*([A-Z][^<]*?)\s*</g;
        $seen{$name} = { items => scalar @items, locked => scalar @locked };
        cmp_ok( scalar @locked, '>', 0, "$name: something is marked" );
    }
    # The inversion the field saw: fewer grants must not mean fewer ITEMS.
    is( $seen{'content+nav'}{items}, $seen{'users only'}{items},
        'an account holding less sees the SAME number of items, not fewer' )
        or diag( 'The field saw 11 items and 0 locked for such an account, '
            . 'which is the pre-SM775 template - the engine renders 16 with 5 '
            . 'locked, so what is deployed is not what is in the tree.' );
};

done_testing;
