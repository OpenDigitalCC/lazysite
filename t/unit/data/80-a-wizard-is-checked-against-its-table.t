#!/usr/bin/perl
# SM1355: A WIZARD DEFINITION, CHECKED AGAINST ITS TABLE, AND ITS STEPS.
#
# Lazysite::Data::Wizard on its own: the definition rules (a field the table
# requires is asked by a required step with no `when`, a type the field can
# hold, options for a choice on a text field, the store's own key never asked),
# the step walk (a required step cannot be skipped, an optional one can, a
# `when` decides whether a step is asked, answers are made the stored values),
# and the (available) binding, refused by name on a table with no availability
# field. With the change reverted the module does not exist and (available) is
# a filter on an undeclared field.
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Wizard     ();
use Lazysite::Data::Query      ();

my $d = load_descriptor( 'svc', {
    key => 'id', availability => 'live',
    fields => {
        title => { type => 'text', required => 1 },
        fee   => { type => 'decimal', digits => 6, places => 2 },
        kind  => { type => 'enum', values => [qw(a b c)] },
        tags  => { type => 'text' },
        live  => { type => 'boolean' },
        note  => { type => 'text' },
    } } );
ok( $d->{ok}, 'the table loads' ) or diag explain $d;
is( $d->{availability}, 'live', 'with its availability field' );
my $loader = sub { $d };
my $check  = sub { Lazysite::Data::Wizard::check_definition( 'w', { table => 'svc', steps => $_[0] }, $loader ) };

subtest 'the definition rules' => sub {
    my $title = { field => 'title', ask => 'Title?', type => 'text', required => 1 };
    ok( $check->( [$title] )->{ok}, 'the required field asked, required' );
    is( $check->( [ { %$title, required => 0 } ] )->{rule}, 'required', 'an optional step for a required field' );
    is( $check->( [ { %$title, when => { field => 'x', is => 1 } } ] )->{rule}, 'when', 'a `when` on it' );
    is( $check->( [ { field => 'fee', ask => 'Fee?', type => 'price' } ] )->{rule}, 'required_unasked',
        'a wizard that never asks a required field' );
    is( $check->( [ $title, { field => 'id', ask => 'Id?', type => 'text' } ] )->{rule}, 'auto_key',
        'the store\'s own key' );
    is( $check->( [ $title, { field => 'live', ask => 'Live?', type => 'text' } ] )->{rule}, 'type',
        'a text step on a boolean' );
    is( $check->( [ $title, { field => 'tags', ask => 'Tags?', type => 'choices' } ] )->{rule}, 'options',
        'choices on a text field without options' );
    is( $check->( [ $title, { field => 'tags', ask => 'Tags?', type => 'choices', options => [ 'a,b' ] } ] )->{rule},
        'options', 'an option holding a comma' );
    is( $check->( [ $title, { field => 'kind', ask => 'Kind?', type => 'choice', options => ['z'] } ] )->{rule},
        'options', 'an option the enum does not hold' );
};

my $w = $check->( [
    { field => 'title', ask => 'Title?', type => 'text', required => 1 },
    { field => 'fee',   ask => 'Fee?',   type => 'price' },
    { field => 'kind',  ask => 'Kind?',  type => 'choice' },
    { field => 'live',  ask => 'Live?',  type => 'yesno' },
    { field => 'note',  ask => 'Why not?', type => 'text', when => { field => 'live', is => JSON::PP::false() } },
    { field => 'tags',  ask => 'Tags?',  type => 'choices', options => [qw(x y z)] },
] );
ok( $w->{ok}, 'a wizard' ) or diag explain $w;

subtest 'the steps' => sub {
    my $r = Lazysite::Data::Wizard::run_steps( $w, {} );
    is( $r->{question}{field}, 'title', 'the first question' );
    is( Lazysite::Data::Wizard::run_steps( $w, { title => '  ' } )->{kind}, 'required', 'a required step left blank' );
    $r = Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => undef } );
    is( $r->{question}{field}, 'kind', 'an optional step skipped' );
    is_deeply( $r->{question}{options}, [qw(a b c)], 'a choice on an enum offers its values' );
    is( Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => '1,234.5' } )->{answers}{fee}, '1234.5',
        'a price loses its thousands comma' );
    is( Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => '€3' } )->{answers}{fee}, '3', '...and its currency sign' );
    is( Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => 'free' } )->{kind}, 'answer', 'a non-amount is refused' );
    is( Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => undef, kind => 'q' } )->{kind}, 'answer', 'an answer not on offer' );
    $r = Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => undef, kind => 'b', live => 'yes', note => 'n', tags => 'z, x' } );
    ok( $r->{complete}, 'complete when live is yes' ) or diag explain $r;
    is_deeply( $r->{not_asked}, ['note'], 'the note was not asked, and its answer is left out' );
    is( $r->{row}{tags}, 'x,z', 'choices in their listed order' );
    is( $r->{row}{live}, 1, 'yes is true' );
    $r = Lazysite::Data::Wizard::run_steps( $w, { title => 'T', fee => undef, kind => 'b', live => JSON::PP::false() } );
    is( $r->{question}{field}, 'note', 'live is no, so the note is asked' );
    is( Lazysite::Data::Wizard::run_steps( $w, { nope => 1 } )->{rule}, 'answers', 'an answer to no question' );
};

subtest '(available) needs an availability field' => sub {
    my $q = Lazysite::Data::Query::parse_binding( 'db:svc(available)', $d );
    ok( $q->{ok}, 'parsed' ) or diag explain $q;
    is( $q->{filters}{live}, 1, 'a filter on the availability field, switched on' );
    my $plain = load_descriptor( 'plain', { key => 'id', fields => { live => { type => 'boolean' } } } );
    my $no = Lazysite::Data::Query::parse_binding( 'db:plain(available)', $plain );
    is( $no->{kind}, 'no_availability', 'refused by name on a table without one' );
};

done_testing();
