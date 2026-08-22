#!/usr/bin/perl
# DP-4: a form submission becomes a row in a typed table.
#
# THIS IS THE ANONYMOUS WRITE PATH, AND THE ONLY ONE. lazysite-data.pl refuses
# an anonymous POST and tells the caller a form is how you collect data from
# visitors; this is the thing it points at. What makes a form the right place
# is not the storage but everything around it - rate limits, spam assessment,
# quarantine, an audit trail, and a handler an operator configured.
#
# THE PROPERTY WORTH PROVING is that the operator decides everything
# structural and the visitor decides only values. The table and the column
# names come from handlers.conf, which no visitor can write. A form field
# nobody mapped is dropped rather than guessed at - so a form growing a field
# cannot grow a column, and a submitted field called `role` cannot become one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; require DB_File; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP/DB_File not available';
}
use TestHelper qw(repo_root);
use Lazysite::Data::Tables qw(apply_schema read_rows);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/forms",
    "$docroot/lazysite/logs" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;

open my $df, '>', "$docroot/lazysite/db/tables/enquiries.yaml" or die $!;
print {$df} <<'YAML';
key: ref
fields:
  ref:
    type: text
  name:
    type: text
  body:
    type: text
  wanted_on:
    type: date
YAML
close $df;
apply_schema( $docroot, 'enquiries' );

open my $hf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hf} <<'CONF';
handlers:
  - id: store
    type: db
    table: enquiries
    fields: ref=ref,name=name,message=body,when=wanted_on
CONF
close $hf;

# ENABLED STATE LIVES IN lazysite.conf's `plugins:` LIST, not in a file of its
# own - checked rather than assumed, because the first version of this fixture
# wrote a plugins.conf that nothing reads, so the "disabled" subtest ran
# against an enabled plugin and passed for no reason.
sub set_plugins {
    my ($on) = @_;
    open my $f, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$f} "site_name: T\n";
    print {$f} "plugins:\n  - plugins/data.pl\n" if $on;
    close $f;
}
set_plugins(1);

# dispatch_db takes the handler config and the parsed form - exactly what
# dispatch() hands it. Driving it directly keeps this file about the DB half;
# the surrounding form machinery has its own tests.
#
# LOADING THE PLUGIN EMITS AN HTTP RESPONSE. It has no `unless caller` guard -
# plugins/data.pl has one, so the convention exists and this file simply lacks
# it - so its top level runs and prints `Status: 200 OK` with a JSON body onto
# STDOUT, straight into the middle of the TAP stream. The run came apart with
# "tests out of sequence", which reads as a broken product rather than a
# harness picking up somebody else's output.
#
# Redirected with select() rather than by reopening the handle: Test::Builder
# CACHES STDOUT and STDERR, so closing and reopening either one breaks the
# harness itself. select() moves only the default handle that an unqualified
# print uses, which is exactly what the plugin writes to and nothing that
# Test::More touches.
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    my $swallowed = '';
    open my $sink, '>', \$swallowed or die $!;
    my $prev = select $sink;
    do "$root/plugins/form-handler.pl";
    select $prev;
    close $sink;

    ok( defined &main::dispatch_db, 'the db handler is defined' )
        or BAIL_OUT( "could not load form-handler.pl: " . ( $@ || $! || '?' ) );
    like( $swallowed, qr/Status:/,
        'and loading it emitted an HTTP response, which this file absorbed' )
        or diag( 'If this stops matching, the plugin has grown a caller guard '
            . 'and the redirect above is no longer needed.' );
}
{ no warnings 'once'; $main::DOCROOT = $docroot; }

my %handler = (
    type   => 'db',
    table  => 'enquiries',
    fields => 'ref=ref,name=name,message=body,when=wanted_on',
);

sub rows { return read_rows( $docroot, 'enquiries', as => 'operator' )->{rows} || [] }

subtest 'a submission becomes a row' => sub {
    my $ok = main::dispatch_db( \%handler,
        {   _form   => 'contact',
            ref     => 'E1',
            name    => 'Ada',
            message => 'Please call',
            when    => '2026-09-01',
        } );
    ok( $ok, 'it reports delivered' );

    my ($r) = grep { $_->{ref} eq 'E1' } @{ rows() };
    ok( $r, 'the row is there' );
    is( $r->{name}, 'Ada',         'with the mapped value' );
    is( $r->{body}, 'Please call', 'under the mapped COLUMN name, not the form field name' )
        or diag( 'The mapping reads FORM=COLUMN. If this is undef the two are '
            . 'the wrong way round.' );
};

subtest 'AN UNMAPPED FIELD IS DROPPED, NOT STORED' => sub {
    # The submitter controls the form's field names. If an unmapped field found
    # its way into the row, a visitor could write to any column they could
    # guess - which is the whole reason the mapping is operator-only.
    my $ok = main::dispatch_db( \%handler,
        {   _form => 'contact',
            ref   => 'E2',
            name  => 'Grace',
            body  => 'INJECTED',       # a real column, but nobody mapped to it
            wanted_on => '1999-01-01', # likewise
        } );
    ok( $ok, 'the submission still succeeds' );

    my ($r) = grep { $_->{ref} eq 'E2' } @{ rows() };
    ok( $r, 'the row is stored' );
    is( $r->{body}, undef, 'the unmapped column is untouched' )
        or diag( 'A submitted field named after a column must not reach it. '
            . 'Only the operator names columns.' );
    is( $r->{wanted_on}, undef, 'and so is the second one' );
};

subtest 'a value the descriptor refuses fails the delivery' => sub {
    my $ok = main::dispatch_db( \%handler,
        { _form => 'contact', ref => 'E3', when => '32nd of Never' } );
    ok( !$ok, 'the handler reports NOT delivered' )
        or diag( 'A visitor thanked for a submission that was silently '
            . 'dropped is the worst available outcome. Reporting failure lets '
            . 'the form tell them.' );
    ok( !( grep { $_->{ref} eq 'E3' } @{ rows() } ), 'and nothing is stored' );
};

subtest 'the operator has to say where it goes' => sub {
    ok( !main::dispatch_db( { type => 'db', fields => 'a=b' },
            { _form => 'c', a => 'x' } ),
        'no table: refused' );
    ok( !main::dispatch_db( { type => 'db', table => 'enquiries' },
            { _form => 'c', name => 'x' } ),
        'no fields mapping: refused' )
        or diag( 'Mapping same-named fields automatically would mean a form '
            . 'gaining a field silently starts writing a column.' );
    ok( !main::dispatch_db(
            { type => 'db', table => '../../etc/passwd', fields => 'a=b' },
            { _form => 'c', a => 'x' } ),
        'a table name that is not one: refused' );
    ok( !main::dispatch_db(
            { type => 'db', table => 'enquiries', fields => 'name=../evil' },
            { _form => 'c', name => 'x' } ),
        'a column name that is not one: refused' );
};

subtest 'OFF MEANS OFF, on this path too' => sub {
    # SM409. A form quietly writing to a table an operator has switched off
    # would be the plugin still running after being turned off.
    set_plugins(0);
    my $before = scalar @{ rows() };
    ok( !main::dispatch_db( \%handler,
            { _form => 'contact', ref => 'E9', name => 'Nope' } ),
        'the handler refuses while the data plugin is disabled' );
    set_plugins(1);
    is( scalar @{ rows() }, $before, 'and stored nothing' );
};

done_testing();
