package LazysiteTest::OdooOps::Week;

# Test pack (SM1186, OOM Lab L-18): a read whose operation refuses what it was
# given, the way a timesheet week refuses a bad ?date=. `date` picks which
# refusal: a plain usage error with a fix line, and the shapes that must NOT
# reach a page whole (over-long, control characters, a host path, a fault).
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.week' }
sub summary    { 'A week of products, by date' }
sub params     { return { date => { type => 'str', default => '' } } }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my $d = $self->param('date');
    my $u = sub { Odoo::Error->throw( kind => 'usage', message => $_[0], ( defined $_[1] ? ( fix => $_[1] ) : () ) ) };
    $u->( "shop.week: date '$d' is not a date", 'give the date as YYYY-MM-DD' ) if $d eq 'bad';
    $u->( 'shop.week: ' . ( 'many words ' x 100 ) ) if $d eq 'long';
    $u->( "shop.week: first line\nsecond\e[31m line\0 end", "fix\tit\r\nnow" ) if $d eq 'ctrl';
    $u->( 'cannot read /srv/secret/plans/42/rows.csv: No such file or directory', 'check the path exists and this user can read it' )
        if $d eq 'path';
    $u->( 'a secret ' . ( 'A' x 40 ) . ' was given' ) if $d eq 'token';
    Odoo::Error->throw( kind => 'fault', message => 'Traceback (most recent call last): /opt/odoo/x.py api_key=abc123' )
        if $d eq 'fault';
    return { rows => $self->model('x.product')->search_read( [], ['name'] ) };
}

1;
