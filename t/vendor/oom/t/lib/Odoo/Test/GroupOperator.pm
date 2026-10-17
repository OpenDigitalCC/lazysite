package Odoo::Test::GroupOperator;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use JSON::PP ();
use File::Temp qw(tempdir);

use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Core::User;
use Odoo::Ops::Runner;
use Odoo::Ops::Runs;

# A user with the groups the caller names and nothing else (the mass-mailing
# group when none is named; see Odoo::Test::MailOperator, of which this is
# the same helper with the groups and a label as options), for a live test
# that needs a right the ops login has not: t/59 makes it an exception
# manager, because the ops login of hr18 may read exception rules but not
# create them. Made
# through core.user under the caller's stamp, given a password from a 0600
# file under tmp/ of the working tree, and written as a config copy
# (credential = password) at the path the caller names - the main checkout's
# tmp/ops-mailop<series>.conf, never committed - which is removed with the
# user at the end. Nothing here is printed: not the password, not the config.
#
#   my $op = Odoo::Test::GroupOperator->make( cfg => $admin_cfg, odoo => $client, stamp => $stamp, conf => $path,
#       groups => ['base_exception.group_exception_rule_manager'], label => 'excop' );
#   my $cfg = $op->config;     # an Odoo::Ops::Config for the operator
#   $op->remove;               # the user, its partner, the files

my $DEFAULT_GROUP = 'mass_mailing.group_mass_mailing_user';

sub _spew ($path, $text) {
    open my $fh, '>', $path or die "cannot write $path: $!";
    chmod 0600, $path;
    print {$fh} $text;
    close $fh;
}

sub _password () {
    open my $fh, '<', '/dev/urandom' or die "no /dev/urandom: $!";
    read $fh, my $raw, 18;
    close $fh;
    ( my $pw = unpack 'H*', $raw ) =~ s/^(.{4})/$1-/;
    return "Op-$pw";
}

sub make ($class, %o) {
    my ( $cfg, $odoo, $stamp, $conf ) = @o{qw(cfg odoo stamp conf)};
    my $groups = $o{groups} // [$DEFAULT_GROUP];
    my $label  = $o{label} // 'mailop';
    my $runs = $cfg->get('runs_dir');
    my $login = lc("$stamp-$label") . '@oom.example';
    my $ctx = sub { Odoo::Ops::Context->new( config => $cfg ) };
    my $apply = sub ($plan) {
        my $dir = tempdir( 'groupop-XXXX', DIR => $runs );
        Odoo::Ops::Runs->approve_plan( $dir, $plan, by => 'live-test' );
        return Odoo::Ops::Runner->apply( $ctx->(), $plan, dir => $dir );
    };
    my $plan = sub (@rows) { Odoo::Ops::Core::User->new( ctx => $ctx->(), params => { records => \@rows } )->run };

    my $r = $apply->( $plan->( { action => 'create', login => $login, name => "OOM Operator $label $stamp", groups => $groups, email => $login } ) );
    die "the mail operator was not made\n" if !$r->ok;

    my $tmp = 'tmp';
    mkdir $tmp if !-d $tmp;
    my $pwfile = File::Spec->rel2abs( File::Spec->catfile( $tmp, "$label-$stamp.pw" ) );
    _spew( $pwfile, _password() . "\n" );
    $r = $apply->( $plan->( { action => 'password', login => $login, password_file => $pwfile } ) );
    die "the mail operator has no password\n" if !$r->ok;

    my @copy = map { defined $cfg->get($_) ? "$_ = " . $cfg->get($_) : () } qw(url db ssl_ca_file runs_dir name);
    _spew( $conf, join( "\n", @copy, 'allow_writes = 1', "login = $login", 'credential = password', "password_file = $pwfile" ) . "\n" );

    my $uid = $odoo->model('res.users')->search( [ [ 'login', '=', $login ] ] )->[0];
    return bless { odoo => $odoo, login => $login, uid => $uid, conf => $conf, pwfile => $pwfile, done => 0 }, $class;
}

sub login ($self) { $self->{login} }
sub uid   ($self) { $self->{uid} }
sub conf  ($self) { $self->{conf} }
sub config ($self) { Odoo::Ops::Config->load( $self->{conf} ) }

# a plain client signed in as the operator (no scope guard), for the checks of what the user may not read;
# the password is read from its file here and goes nowhere else
sub client ($self) {
    require Odoo::Client;
    my $cfg = $self->config;
    open my $fh, '<', $self->{pwfile} or die "cannot read the operator's password file: $!";
    chomp( my $pw = <$fh> );
    close $fh;
    return Odoo::Client->new( ( map { $_ => $cfg->get($_) } grep { defined $cfg->get($_) } qw(url db ssl_ca_file) ),
        login => $self->{login}, password => $pw, transport => 'jsonrpc', retries => [0] );
}

# the groups the user holds, as xml ids, read as the administrator
sub groups ($self) {
    my $odoo   = $self->{odoo};
    my $field  = $odoo->model('res.users')->fields->{group_ids} ? 'group_ids' : 'groups_id';
    my $ids    = $odoo->model('res.users')->read_one( $self->{uid}, [$field] )->{$field};
    my $rows   = @$ids ? $odoo->model('ir.model.data')->search_read( [ [ 'model', '=', 'res.groups' ], [ 'res_id', 'in', $ids ] ], [qw(module name)] ) : [];
    return [ sort map { "$_->{module}.$_->{name}" } @$rows ];
}

# the user, its partner (unless something else holds it) and the two files; a user Odoo will not delete is archived
sub remove ($self) {
    return if $self->{done}++;
    my $odoo = $self->{odoo};
    my $note = '';
    if ( $self->{uid} ) {
        my $users = $odoo->model('res.users');
        my $row = $users->read( [ $self->{uid} ], ['partner_id'] )->[0];
        my $partner = $row && ref $row->{partner_id} ? $row->{partner_id}[0] : undef;
        if ( !eval { $users->unlink( [ $self->{uid} ] ); 1 } ) {
            $note = "the user could not be deleted (archived instead): $@";
            eval { $users->write( [ $self->{uid} ], { active => JSON::PP::false } ); 1 };
        }
        elsif ($partner) {
            eval { $odoo->model('res.partner')->unlink( [$partner] ); 1 } or $note = "the partner $partner stays: $@";
        }
    }
    unlink $self->{pwfile}, $self->{conf};
    return $note;
}

sub DESTROY ($self) { eval { $self->remove } }

1;
