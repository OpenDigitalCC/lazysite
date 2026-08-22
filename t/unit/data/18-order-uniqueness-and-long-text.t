#!/usr/bin/perl
# Three findings from the field agent's attempt to describe a real site's data
# (a painting gallery), each small on its own and each a thing they could not
# say at all:
#
#   F-1  "A gallery is an ORDERED list - the artist chose the sequence."
#        There was no way to say what order a table's rows are in, so a bare
#        binding returned them in whatever order the store handed back.
#
#   F-4  "Long text and short text are the same type." A 500-character
#        description and a short title are both `text`, which is right - they
#        are the same kind of value - but nothing could say how to EDIT them.
#
#   F-5  "Uniqueness only via key." They could not say "slug is unique" while
#        keying on something else, and worked around it by keying on the slug -
#        changing what a row IS in order to state a constraint about one of its
#        values.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Query      qw(parse_binding);
use Lazysite::Data::Tables     qw(apply_schema insert_row read_rows load_table);
use Lazysite::Data::Schema     qw(plan_migration);
use Lazysite::Data::Connect    ();

sub desc {
    my (%extra) = @_;
    return load_descriptor(
        'works',
        {   key    => 'ref',
            fields => {
                ref   => { type => 'text' },
                pos   => { type => 'integer' },
                slug  => { type => 'text' },
                title => { type => 'text' },
            },
            %extra,
        }
    );
}

subtest 'F-1: a table can say what order it is in' => sub {
    my $d = desc( default_order => 'pos' );
    ok( $d->{ok}, 'the descriptor loads' ) or diag( $d->{error} );
    is( $d->{default_order},     'pos', 'the field is recorded' );
    is( $d->{default_order_dir}, 'asc', 'ascending by default' );

    my $r = desc( default_order => '-pos' );
    is( $r->{default_order},     'pos',  'a leading - names the same field' );
    is( $r->{default_order_dir}, 'desc', 'and reverses it' );

    ok( !desc( default_order => 'nosuch' )->{ok},
        'a field that does not exist is refused' )
        or diag( 'An order naming nothing would sort by nothing, silently.' );
};

subtest 'F-1: a binding with no order of its own gets the declared one' => sub {
    my $d = desc( default_order => '-pos' );
    my $q = parse_binding( 'db:works', $d );
    is( $q->{order_by}, 'pos',  'the declared field is used' );
    is( $q->{order},    'desc', 'in the declared direction' );

    # THE AUTHOR STILL WINS. This fills a gap; it does not overrule a binding.
    my $own = parse_binding( 'db:works(order=title)', $d );
    is( $own->{order_by}, 'title', 'a binding that says otherwise is obeyed' )
        or diag( 'A default that cannot be overridden is not a default.' );

    my $plain = parse_binding( 'db:works', desc() );
    is( $plain->{order_by}, undef, 'and a table with no declared order gets none' );
};

subtest 'F-4: a field can say it holds long text' => sub {
    my $d = load_descriptor( 'works',
        { fields => { note => { type => 'text', widget => 'textarea' } } } );
    ok( $d->{ok}, 'textarea is accepted' ) or diag( $d->{error} );

    my $bad = load_descriptor( 'works',
        { fields => { note => { type => 'text', widget => 'textarea!' } } } );
    ok( !$bad->{ok}, 'a widget that is not one is refused' )
        or diag( 'A typo here becomes a text box that silently never became a '
            . 'text area - the kind of thing nobody reports as a bug.' );

    # THE VOCABULARY WAS ALREADY THERE, and adding a second copy of it was the
    # mistake this subtest caught: `widget` has been validated inside the text
    # branch since DP-1, allowing input|textarea. A new list allowing
    # text|textarea ran BEFORE it, so `widget: input` - the documented value -
    # started being refused, and `widget: text` passed one check to fail the
    # other. Two answers to one question, introduced while fixing something
    # else.
    ok( load_descriptor( 'works',
            { fields => { note => { type => 'text', widget => 'input' } } }
        )->{ok},
        'the existing input widget still works' )
        or diag( 'Adding a vocabulary beside an existing one breaks the '
            . 'values that were already valid.' );

    # WHAT WAS ACTUALLY MISSING: the check lives in the text branch, so a
    # widget on any OTHER type was accepted in silence and became an editor
    # hint nothing could honour.
    my $wrong = load_descriptor( 'works',
        { fields => { n => { type => 'integer', widget => 'textarea' } } } );
    ok( !$wrong->{ok}, 'and a widget on a number is refused' );
    like( $wrong->{error}, qr/only meaningful on a text field/, 'saying why' );
};

subtest 'F-5: a field can be unique without being the key' => sub {
    my $d = desc( fields => {
            ref   => { type => 'text' },
            pos   => { type => 'integer' },
            slug  => { type => 'text', unique => 1 },
            title => { type => 'text' },
        } );
    ok( $d->{ok}, 'the descriptor loads' ) or diag( $d->{error} );
    is_deeply( $d->{unique}, ['slug'], 'the field is recorded as unique' );
};

subtest 'F-5: the store enforces it' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/db/tables");
    open my $f, '>', "$docroot/lazysite/db/tables/works.yaml" or die $!;
    print {$f} "key: ref\nfields:\n  ref:\n    type: text\n"
        . "  slug:\n    type: text\n    unique: true\n";
    close $f;
    apply_schema( $docroot, 'works' );

    ok( insert_row( $docroot, 'works', { ref => 'W1', slug => 'dawn' } )->{ok},
        'the first row goes in' );
    my $second
        = insert_row( $docroot, 'works', { ref => 'W2', slug => 'dawn' } );
    ok( !$second->{ok}, 'a second row with the same value is refused' )
        or diag( 'A uniqueness declaration nothing enforces is worse than none '
            . '- it is a promise an operator will rely on.' );

    is( scalar @{ read_rows( $docroot, 'works', as => 'operator' )->{rows} },
        1, 'and only one row is stored' );

    # NULL IS NOT A DUPLICATE. SQLite treats every NULL as distinct in a unique
    # index, so two rows with no slug are both allowed - which is right, and
    # worth pinning because the opposite is a reasonable guess.
    ok( insert_row( $docroot, 'works', { ref => 'W3' } )->{ok}, 'an empty one' );
    ok( insert_row( $docroot, 'works', { ref => 'W4' } )->{ok}, 'and another' );
};

subtest 'F-5: MAKING AN EXISTING FIELD UNIQUE IS REPORTED, NOT ATTEMPTED'
    => sub {
    # CREATE UNIQUE INDEX on a table that already holds duplicates simply
    # fails. A migration that stops half way with a raw engine message about a
    # constraint is what D5 exists to prevent, so the clash is found first and
    # the value is named.
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/db/tables");
    my $path = "$docroot/lazysite/db/tables/works.yaml";
    open my $f, '>', $path or die $!;
    print {$f} "key: ref\nfields:\n  ref:\n    type: text\n"
        . "  slug:\n    type: text\n";
    close $f;
    apply_schema( $docroot, 'works' );
    insert_row( $docroot, 'works', { ref => 'W1', slug => 'dawn' } );
    insert_row( $docroot, 'works', { ref => 'W2', slug => 'dawn' } );

    open my $f2, '>', $path or die $!;
    print {$f2} "key: ref\nfields:\n  ref:\n    type: text\n"
        . "  slug:\n    type: text\n    unique: true\n";
    close $f2;

    my $d    = load_table( $docroot, 'works' );
    my $dbh  = Lazysite::Data::Connect::read_handle($docroot);
    my $plan = plan_migration( $d, $dbh );

    ok( $plan->{ok}, 'a plan is produced' );
    my ($b) = grep { ( $_->{field} // '' ) eq 'slug' } @{ $plan->{blocked} };
    ok( $b, 'and the change is BLOCKED rather than attempted' )
        or diag( 'Attempting it produces a failed migration and an engine '
            . 'message about an index, which names nothing an operator can '
            . 'act on.' );
    like( $b->{why}, qr/dawn/, 'naming the value that is in two rows' )
        or diag( 'Telling an operator "there are duplicates" leaves them to '
            . 'find which. Naming one is the whole difference.' );
    ok( !( grep { ( $_->{why} // '' ) =~ /unique/ } @{ $plan->{additive} } ),
        'and it is not also queued as an additive step' );
};

done_testing();
