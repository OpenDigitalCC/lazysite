#!/usr/bin/perl
# SM1328 (ruling 52, T-13): ONE SETTING, odoo_display_name, NAMES ODOO in every
# dialog label and error text a visitor or a manager reads. Absent it is "Odoo" (the
# texts as they were); a value is that name; an empty value is no name, and each text
# then reads whole without one.
#
# Held here: the one reader (Lazysite::Odoo::Name), the errors the page endpoint
# answers (every fault kind, the sign-in's own refusals, a refused change's
# withheld reason, the unknown-runs listing's name), and the browser helper's dialog
# and messages (t/lib/odoo-name-harness.js under node). The pages are
# t/unit/processor/172.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_child site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
make_path("$d/lazysite");

sub name_is {
    my ($v) = @_;
    open my $fh, '>', "$d/lazysite/odoo.conf" or die $!;
    print {$fh} "odoo_url: https://odoo.example\n";
    print {$fh} "odoo_display_name: $v\n" if defined $v;
    close $fh;
}

require Lazysite::Odoo::Name;

subtest 'the one reader: absent, a name, empty' => sub {
    name_is(undef);
    is( Lazysite::Odoo::Name::display_name("$d/lazysite"), 'Odoo', 'absent: Odoo' );
    is( Lazysite::Odoo::Name::display_name(undef), 'Odoo', 'no site at all: Odoo' );
    name_is('Acme Office');
    is( Lazysite::Odoo::Name::display_name("$d/lazysite"), 'Acme Office', 'a value: that name' );
    name_is('  Acme Office  ');
    is( Lazysite::Odoo::Name::display_name("$d/lazysite"), 'Acme Office', 'without its outer spaces' );
    name_is('');
    is( Lazysite::Odoo::Name::display_name("$d/lazysite"), '', 'empty: no name' );
    is( Lazysite::Odoo::Name::phrase( 'Sign in to {name}', 'Sign in', "$d/lazysite" ), 'Sign in', 'and the text without it' );
    name_is('Acme Office');
    is( Lazysite::Odoo::Name::phrase( '{name} said no; ask {name}', 'no', "$d/lazysite" ), 'Acme Office said no; ask Acme Office',
        'every {name} is the name' );
};

my $have_oom = eval { require Odoo::Error; 1 };
SKIP: {
    skip 'OOM (Odoo::Error) is not installed', 2 unless $have_oom;
    require Lazysite::Odoo;
    require Lazysite::Odoo::Session;
    no warnings 'once';
    $Lazysite::Odoo::DOCROOT = $d;

    my @errs = (
        ( map { { kind => 'fault', fault_class => $_ } } qw(odoo.exceptions.AccessError odoo.exceptions.AccessDenied
              odoo.http.SessionExpiredException odoo.exceptions.ValidationError odoo.exceptions.MissingError) ),
        { kind => 'fault' }, { kind => 'transport' }, { kind => 'config' },
        ( map { { kind => 'refused', code => $_ } } qw(redirect oversize read-only instance stale unknown-outcome nonesuch) ),
    );
    sub quiet { my ($c) = @_; my $log = ''; local *STDERR; open STDERR, '>', \$log or die $!; return $c->() }
    sub texts {
        my @t = map { my $e = $_; quiet( sub { Lazysite::Odoo::fault( Odoo::Error->new( message => 'x', %$e ) )->{error} } ) } @errs;
        push @t, quiet( sub { Lazysite::Odoo::fault('a perl error')->{error} } );
        push @t, Lazysite::Odoo::Session::identity_of( {}, undef )->{error};
        push @t, ( Lazysite::Odoo::Session::_classify( Odoo::Error->new( kind => 'transport', message => 'x' ) ) )[1];
        push @t, Lazysite::Odoo::said(@Lazysite::Odoo::UNKNOWN_ANSWER);
        return @t;
    }

    subtest 'the endpoint\'s errors: Odoo by default, the name, or none' => sub {
        name_is(undef);
        my @default = texts();
        is( scalar( grep { /\bOdoo\b/ } @default ), scalar(@default), 'absent: every one of these says Odoo, as before' );
        name_is('Acme Office');
        my @named = texts();
        is_deeply( \@named, [ map { ( my $t = $_ ) =~ s/\bOdoo\b/Acme Office/g; $t } @default ],
            'a name: each says it where it said Odoo, and is otherwise the same' );
        name_is('');
        my @plain = texts();
        is( scalar( grep { /\bOdoo\b|Acme|\{name\}/ } @plain ), 0, 'empty: none names anything' ) or diag explain \@plain;
        is( scalar( grep { /\A\s|\s\z|  |\(\s|\s[,.;:]/ } @plain ), 0, '...and none has a hole where the name was' )
            or diag explain \@plain;
        is( scalar( grep { length } @plain ), scalar(@default), '...and each still says something' );
    };

    subtest 'the manager\'s unknown-runs listing answers the name' => sub {
        no warnings 'redefine';
        local *Lazysite::Odoo::_extension_enabled = sub { 1 };
        name_is('Acme Office');
        my $r = Lazysite::Odoo::action_odoo_unknown_runs( caps => { $Lazysite::Odoo::SETTLE_CAP => 1 } );
        ok( $r->{ok}, 'listed' ) or diag explain $r;
        is( $r->{display_name}, 'Acme Office', 'with the name' );
        name_is('');
        is( Lazysite::Odoo::action_odoo_unknown_runs( caps => { $Lazysite::Odoo::SETTLE_CAP => 1 } )->{display_name}, '',
            'empty: an empty name, which the panel says as none' );
    };
}

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node is not installed', 1 unless length $node && -x $node;
    subtest 'the browser helper\'s dialog and messages' => sub {
        my $r = run_child( [ $node, "$root/t/lib/odoo-name-harness.js", "$root/starter/assets/lazysite-odoo.js" ], stderr => 'merge' );
        my $f = eval { decode_json( $r->{out} ) };
        ok( $f && !$f->{error}, 'the harness ran' ) or return diag( $r->{out} // '' );
        my %want = (
            none => [ 'Sign in to Odoo', 'Sign in to Odoo to continue.', 'Odoo login', 'Odoo password',
                'Odoo could not be reached. Try again.', 'It is not known whether Odoo made this change.',
                'It is not known whether Odoo made these changes.' ],
            named => [ 'Sign in to Acme Office', 'Sign in to Acme Office to continue.', 'Acme Office login', 'Acme Office password',
                'Acme Office could not be reached. Try again.', 'It is not known whether Acme Office made this change.',
                'It is not known whether Acme Office made these changes.' ],
            empty => [ 'Sign in', 'Sign in to continue.', 'Login', 'Password', 'No answer came. Try again.',
                'It is not known whether this change was made.', 'It is not known whether these changes were made.' ],
        );
        my %why = ( none => 'no name on the script tag: Odoo, as before', named => 'a name', empty => 'an empty name: none' );
        for my $case (qw(none named empty)) {
            is_deeply( [ @{ $f->{$case} }{qw(dialog message login password unreachable unknown_one unknown_two)} ],
                $want{$case}, $why{$case} );
        }
    };
}

done_testing;
