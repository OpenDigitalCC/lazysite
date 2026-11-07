#!/usr/bin/perl
# SM1369 X3 (ruling 55, H-3): A DELIVERY HANDLER TYPE IS DECLARED BY THE EXTENSION.
#
# An extension's `owns.hooks.handler_types` puts a type in the handler catalogue
# (Lazysite::Handlers) with what a core type has - label, cap, schema - and four
# functions core calls from the extension's own payload lib: `parse` and
# `on_save` at save, `on_delete` at delete, `deliver` from an origin the type
# lists. Core keeps what belongs to the shared catalogue: the schema check that
# refuses an unknown key, the cap gate, the origin gate, the delivery record;
# the extension decides what its type does.
#
# Driven through a fixture extension, enabled and indexed by the real build.
#
#   * the declaration's vocabulary is checked before it is indexed: a core
#     type's name, a retired one, a capability nobody declares, an origin core
#     has not got, a field type the catalogue does not draw;
#   * the catalogue: the type is offered with its label, cap and schema, and
#     none of its functions; its cap gates saving it, as a core type's does;
#   * save: an unknown key is refused by core's schema check; the extension's
#     `parse` refuses a shape with the field it is about; `on_save` refuses a
#     destination and keeps its own record when it accepts;
#   * delete: `on_delete` runs and the record goes;
#   * deliver: from a form, with the visible fields only, the host, the
#     origin; from the timer, REFUSED by core before the extension runs, naming
#     the origins; a `deliver` that dies is a failed delivery with its reason;
#   * `address_list` (I-13): the profiles a handler names are found by the
#     field's type and slot, whichever type carries them;
#   * off: with the extension disabled the type leaves the catalogue, a saved
#     handler of it is a named problem and is not delivered.
#
# Sabotage: drop the origin test in Handlers::_to_extension and the timer
# delivers - this fails. Drop `address_list` from AddressRefs' field walk and the
# profile walk finds nothing.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                    qw(site_tempdir);
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_disable);
use Lazysite::Extensions::Hooks   qw(validate_hooks);
use Lazysite::Handlers            ();
use Lazysite::Auth::AddressRefs   ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

sub errors { return [ map { $_->{error} } @_ ] }

my $N = 0;

sub type_decl {
    my (%over) = @_;
    return {
        label   => 'Probe delivery',
        cap     => 'manage_forms',
        origins => ['form'],
        schema  => [
            { key => 'target',        label => 'Target', type => 'text', required => 1 },
            { key => 'from_profiles', label => 'From', type => 'address_list', slot => 'allow' },
            { key => 'never_from', label => 'Never from', type => 'address_list', slot => 'deny' },
        ],
        parse     => 'Probe::Handler::parse',
        on_save   => 'Probe::Handler::on_save',
        on_delete => 'Probe::Handler::on_delete',
        deliver   => 'Probe::Handler::deliver',
        %over,
    };
}

# A site with the probe extension beside it: a handler type whose functions
# record what they were handed under lazysite/probe/.
sub fixture {
    my $M    = 'Probe' . ++$N;
    my $d    = site_tempdir();
    my $base = dirname($d);
    make_path( "$d/lazysite/forms", "$base/extensions/probe/lib/${M}" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    my $decl = type_decl();
    $_ =~ s/\AProbe::/${M}::/ for @{$decl}{qw(parse on_save on_delete deliver)};
    write_extension( "$base/extensions/probe.pl", {
            id => 'probe', name => 'Probe', contract => 1,
            config_file => 'lazysite/probe.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ],
            owns => { hooks => { handler_types => { probe => $decl } } } } );
    spit( "$base/extensions/probe/lib/${M}/Handler.pm", <<"PM" );
package ${M}::Handler;
use strict; use warnings; use JSON::PP ();
sub _dir { my (\$c) = \@_; my \$p = "\$c->{docroot}/lazysite/probe"; mkdir \$p; return \$p }
sub parse {
    my (\$h, \$ctx) = \@_;
    return { ok => 0, why => "target: '\$h->{target}' is not a target", field => 'target' } if \$h->{target} eq 'bad';
    return { ok => 1 };
}
sub on_save {
    my (\$h, \$ctx) = \@_;
    return { ok => 0, why => "target: '\$h->{target}' cannot be reached" } if \$h->{target} eq 'unreachable';
    open my \$fh, '>', _dir(\$ctx) . "/\$h->{id}.saved" or die \$!; print {\$fh} \$h->{target}; close \$fh;
    return { ok => 1 };
}
sub on_delete { my (\$h, \$ctx) = \@_; unlink _dir(\$ctx) . "/\$h->{id}.saved"; return { ok => 1 } }
sub deliver {
    my (\$h, \$fields, \$ctx) = \@_;
    die "the probe fell over\\n" if \$h->{target} eq 'die';
    open my \$fh, '>', _dir(\$ctx) . "/\$h->{id}.delivered" or die \$!;
    print {\$fh} JSON::PP->new->canonical->encode({ fields => \$fields, ctx => \$ctx }); close \$fh;
    return { ok => 0, why => 'told to fail' } if \$fields->{fail};
    return { ok => 1, note => 'probed' };
}
1;
PM
    $Lazysite::Manager::Extensions::DOCROOT = $d;
    $Lazysite::Handlers::DOCROOT            = $d;
    my $r = action_extension_enable('extensions/probe.pl');
    die 'the fixture did not enable: ' . ( $r->{error} // '?' ) unless $r->{ok};
    return ( $base, $d );
}

sub save {
    my (%h) = @_;
    my %who = exists $h{_who} ? %{ delete $h{_who} } : ( unconstrained => 1 );
    return Lazysite::Handlers::action_handler_save( { type => 'probe', name => $h{id}, %h }, %who );
}

subtest 'the vocabulary is checked before it is indexed' => sub {
    my $ok = errors( validate_hooks( 'x', { handler_types => { probe => type_decl() } } ) );
    is_deeply( $ok, [], 'a sound type passes' ) or diag explain $ok;
    my %bad = (
        'a core type\'s name'          => { smtp    => type_decl() },
        'a retired type\'s name'       => { webhook => type_decl() },
        'a name a type may not use'    => { Probe   => type_decl() },
        'a capability nobody declares' => { probe => type_decl( cap => 'manage_probes' ) },
        'an origin core has not got' => { probe => type_decl( origins => [ 'form', 'page' ] ) },
        'no origin at all'           => { probe => type_decl( origins => [] ) },
        'a field type the catalogue does not draw' =>
            { probe => type_decl( schema => [ { key => 'target', label => 'T', type => 'wizard' } ] ) },
        'a schema key every handler carries' =>
            { probe => type_decl( schema => [ { key => 'id', label => 'T', type => 'text' } ] ) },
        'a slot that is not one' =>
            { probe => type_decl( schema => [ { key => 'x', label => 'T', type => 'address_list', slot => 'maybe' } ] ) },
        'no deliver' => { probe => do { my $t = type_decl(); delete $t->{deliver}; $t } },
        'a function that is not one' => { probe => type_decl( deliver => 'main::system' ) },
        'a note that is not plain'   => { probe => type_decl( note => [] ) },
    );
    for my $what ( sort keys %bad ) {
        my $e = errors( validate_hooks( 'x', { handler_types => $bad{$what} } ) );
        ok( scalar @$e, "refused: $what" ) or diag explain $bad{$what};
    }
    like( errors( validate_hooks( 'x', { handler_types => { probe => type_decl( cap => 'manage_probes' ) } } ) )->[0],
        qr/cap 'manage_probes' is not a capability/, 'the capability refusal names it' );
    like( errors( validate_hooks( 'x', { handler_types => { probe => type_decl( origins => ['page'] ) } } ) )->[0],
        qr/'page' is not an origin \(the origins are: form, timer\)/, 'the origin refusal lists the origins' );
};

subtest 'the catalogue offers the type as it offers a core one' => sub {
    my ( $base, $d ) = fixture();
    my ($t) = grep { $_->{type} eq 'probe' } @{ Lazysite::Handlers::types() };
    ok( $t, 'the type is in the catalogue' ) or return;
    is( $t->{label},     'Probe delivery', 'with its label' );
    is( $t->{cap},       'manage_forms',   'its cap' );
    is( $t->{extension}, 'probe',          'and the extension it belongs to' );
    is_deeply( [ map { $_->{key} } @{ $t->{schema} } ], [qw(target from_profiles never_from)], 'its schema' );
    ok( !( grep { exists $t->{$_} } qw(hook parse on_save on_delete deliver) ), 'and none of its functions' );
    is( Lazysite::Handlers::cap_for_type('probe'), 'manage_forms', 'cap_for_type answers for it' );
    is( ( grep { $_ eq 'probe' } @Lazysite::Handlers::TYPE_ORDER ), 1, 'listed once, after the core types' );
    my $r = save( id => 'h1', target => 'inbox', _who => { caps => { manage_data => 1 } } );
    is( $r->{kind}, 'forbidden', 'saving one needs its cap' );
    like( $r->{error}, qr/manage_forms/, 'named' );
};

subtest 'save: core checks the schema, the extension checks the shape and the destination' => sub {
    my ( $base, $d ) = fixture();
    my $r = save( id => 'h1', target => 'inbox', extra => 'x' );
    like( $r->{error}, qr/a probe handler does not take: extra/, 'an unknown key is refused by the schema check' );
    is( $r->{field}, 'extra', 'naming the field' );
    $r = save( id => 'h1' );
    like( $r->{error}, qr/target is required for a probe handler/, 'a required field is required' );
    $r = save( id => 'h1', target => 'bad' );
    is( $r->{kind}, 'invalid', 'the extension\'s parse refuses a shape' );
    like( $r->{error}, qr/'bad' is not a target/, 'with its reason' );
    is( $r->{field}, 'target', 'and the field it is about' );
    $r = save( id => 'h1', target => 'unreachable' );
    like( $r->{error}, qr/cannot be reached/, 'on_save refuses a destination' );
    is( $r->{field}, 'target', 'with the field its sentence starts with' );
    ok( !-e "$d/lazysite/probe/h1.saved", 'and kept no record' );
    $r = save( id => 'h1', target => 'inbox', from_profiles => ' office , hq ' );
    ok( $r->{ok}, 'a sound handler saves' ) or diag explain $r;
    is( slurp("$d/lazysite/probe/h1.saved"), 'inbox', 'and on_save kept its own record' );
    is( $r->{handler}{from_profiles}, 'office,hq', 'an address_list is kept as one trimmed list' );
    $r = save( id => 'h2', target => 'inbox', from_profiles => 'not a name!' );
    like( $r->{error}, qr/from_profiles: 'not a name!' is not the name of an address profile/, 'and its names are checked' );
    like( slurp("$d/lazysite/forms/handlers.conf"), qr/^\s+type: probe$/m, 'handlers.conf holds the type as any other' );

    $r = Lazysite::Handlers::action_handler_delete( 'h1', unconstrained => 1 );
    ok( $r->{ok},                         'deleted' ) or diag explain $r;
    ok( !-e "$d/lazysite/probe/h1.saved", 'and on_delete took the extension\'s record with it' );
};

subtest 'deliver: from a form, with the visible fields; from the timer, refused by core' => sub {
    my ( $base, $d ) = fixture();
    ok( save( id => 'h1', target => 'inbox' )->{ok}, 'saved' );
    local $ENV{HTTP_HOST} = 'shop.example';
    my $r = Lazysite::Handlers::deliver( 'h1', { name => 'Ann', _secret => 'no' },
        origin => 'form', source => 'form:contact', ip => '203.0.113.9' );
    ok( $r->{ok}, 'a form delivers' ) or diag explain $r;
    is( $r->{note}, 'probed', 'with the extension\'s note' );
    is( $r->{type}, 'probe',  'and the type on the record' );
    my $got = JSON::PP::decode_json( slurp("$d/lazysite/probe/h1.delivered") );
    is_deeply( $got->{fields}, { name => 'Ann' }, 'the extension got the visible fields only' );
    is( $got->{ctx}{origin},  'form',         'the origin' );
    is( $got->{ctx}{source},  'form:contact', 'the source' );
    is( $got->{ctx}{ip},      '203.0.113.9',  'the address' );
    is( $got->{ctx}{host},    'shop.example', 'the host a form was posted to' );
    is( $got->{ctx}{docroot}, $d,             'and the site' );
    ok( !exists $got->{ctx}{handlers}, 'and not the handler list' );

    unlink "$d/lazysite/probe/h1.delivered";
    $r = Lazysite::Handlers::deliver( 'h1', { name => 'Ann' }, origin => 'timer', source => 'timer:nightly', actor => 'job' );
    ok( !$r->{ok}, 'the timer is refused: the type does not list it' );
    like( $r->{why}, qr/a probe handler does not run from a timer - its origins are: form/, 'naming the origins' );
    ok( !-e "$d/lazysite/probe/h1.delivered", 'and the extension\'s deliver never ran' );

    $r = Lazysite::Handlers::deliver( 'h1', { fail => 1 }, origin => 'form', source => 'form:x' );
    ok( !$r->{ok}, 'the extension can refuse' );
    is( $r->{why}, 'told to fail', 'with its reason' );

    ok( save( id => 'h2', target => 'die' )->{ok}, 'a handler whose deliver dies' );
    $r = Lazysite::Handlers::deliver( 'h2', {}, origin => 'form', source => 'form:x' );
    ok( !$r->{ok}, 'is a failed delivery' );
    like( $r->{why}, qr/deliver did not run: .*died/, 'with the reason, never an exception' );
};

subtest 'address_list: the profiles a handler names are found by the field type' => sub {
    my ( $base, $d ) = fixture();
    ok( save( id => 'h1', target => 'inbox', from_profiles => 'office,hq', never_from => 'bad' )->{ok}, 'saved' );
    is_deeply( Lazysite::Handlers::address_list_fields(),
        { probe => [ { key => 'from_profiles', slot => 'allow' }, { key => 'never_from', slot => 'deny' } ] },
        'the catalogue says which fields of which types name profiles' );
    my $rules = Lazysite::Auth::AddressRefs::rules($d);
    is_deeply( $rules->{faults}, [], 'no faults' );
    is_deeply( [ sort map { "$_->{where} $_->{ref} $_->{slot} $_->{name}" } grep { $_->{where} eq 'binding' } @{ $rules->{rules} } ],
        [ 'binding h1 allow hq', 'binding h1 allow office', 'binding h1 deny bad' ],
        'and the walk finds them, with their slots' );
    like( Lazysite::Auth::AddressRefs::describe( grep { $_->{where} eq 'binding' } @{ $rules->{rules} } ),
        qr/\Ahandler h1\z/, 'described as a handler' );
};

subtest 'off: the type leaves the catalogue and a saved handler of it is not delivered' => sub {
    my ( $base, $d ) = fixture();
    ok( save( id => 'h1', target => 'inbox' )->{ok},           'saved while on' );
    ok( action_extension_disable('extensions/probe.pl')->{ok}, 'the extension is switched off' );
    ok( !( grep { $_->{type} eq 'probe' } @{ Lazysite::Handlers::types() } ), 'the type is gone from the catalogue' );
    is( Lazysite::Handlers::cap_for_type('probe'), undef, 'and has no cap' );
    my $list = Lazysite::Handlers::action_handler_list( unconstrained => 1 );
    my ($h) = grep { $_->{id} eq 'h1' } @{ $list->{handlers} };
    like( $h->{problem}, qr/unknown type 'probe'/, 'the saved handler is listed with its problem' );
    my $r = Lazysite::Handlers::deliver( 'h1', { name => 'Ann' }, origin => 'form', source => 'form:x' );
    ok( !$r->{ok}, 'and is not delivered' );
    like( $r->{why}, qr/unknown type 'probe'/, 'by name' );
    $r = save( id => 'h2', target => 'inbox' );
    like( $r->{error}, qr/no handler type 'probe'/, 'nor can one be saved' );
    ok( action_extension_enable('extensions/probe.pl')->{ok},                'on again' );
    ok( ( grep { $_->{type} eq 'probe' } @{ Lazysite::Handlers::types() } ), 'and the type is back' );
};

done_testing();
