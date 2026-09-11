#!/usr/bin/perl

# SM842: handlers, form bindings and the schedule from a shell - and the one
# conversion an upgrade runs.
#
# ONE IMPLEMENTATION. Every verb here calls Lazysite::Handlers, the same
# functions the manager page, the control API and MCP call. A handler written
# from a shell is the same record, refused for the same reasons, audited the
# same way.
#
# THE ACTOR IS MANDATORY FOR A WRITE, on SM289's argument: there is no session
# behind a shell, and defaulting to an unconstrained identity would make this the
# one surface where the destination does not decide. --actor names the account
# the change is made AS, and it gets exactly the capabilities that account has
# anywhere else. `local` is the documented break-glass identity and is never a
# default.
#
# `convert` needs no actor. It is not a grant: it rewrites old shapes into the
# new one without widening what any handler does, and it is what an upgrade
# runs (install.pl calls it from the freshly installed tree).

use strict;
use warnings;
use Getopt::Long ();
use JSON::PP     ();

BEGIN {
    # SM366: locate the module tree relative to this script (run in place, from
    # a tarball, a Hestia install), falling back to the system @INC.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

use Lazysite::Handlers       ();
use Lazysite::Paths          ();
use Lazysite::Auth::Settings ();

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

# Options first, wherever they sit: `lazysite handlers --domain X convert`
# hands this --docroot and --cgibin ahead of the command.
my %opt = ( docroot => '', actor => '', json => 0, dry_run => 0, set => [], payload => undef );
Getopt::Long::GetOptions(
    'docroot=s' => \$opt{docroot},
    'cgibin=s'  => \my $ignored_cgibin,
    'actor=s'   => \$opt{actor},
    'set=s@'    => $opt{set},
    'payload=s' => \$opt{payload},
    'json'      => \$opt{json},
    'dry-run'   => \$opt{dry_run},
    'help|h'    => sub { usage(0) },
) or usage(2);

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';
usage(0) if $verb eq 'help';
usage(2)                               unless length $verb;
fail('--docroot is required')          unless length $opt{docroot};
fail("not a directory: $opt{docroot}") unless -d $opt{docroot};

my $WRITES = qr/\A(?:save|delete|bind|schedule-save|schedule-delete|convert)\z/x;

# SM139: lazysite never writes into a site tree as root - root-owned files there
# are what stops the manager working afterwards. LAZYSITE_CLI_FAKE_ROOT is the
# test-only override the other tools honour, and like theirs it only ever makes
# this more restrictive.
if ( ( $> == 0 || $ENV{LAZYSITE_CLI_FAKE_ROOT} ) && $verb =~ $WRITES && !$opt{dry_run} ) {
    fail( "refusing to write as root - run it as the site user (sudo -u SITEUSER ...).\n"
            . '  Root-owned files in the site tree are what stops the manager working afterwards (SM139).' );
}

( my $docroot = $opt{docroot} ) =~ s{/+\z}{};
$Lazysite::Handlers::DOCROOT        = $docroot;
$Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Paths::lazysite_dir($docroot) . '/auth';

my %VERB = (
    list              => \&cmd_list,
    save              => \&cmd_save,
    delete            => \&cmd_delete,
    bind              => \&cmd_bind,
    'schedule-list'   => \&cmd_schedule_list,
    'schedule-save'   => \&cmd_schedule_save,
    'schedule-delete' => \&cmd_schedule_delete,
    convert           => \&cmd_convert,
);
my $run = $VERB{$verb} or do {
    print {*STDERR} "lazysite-handlers: unknown sub-command '$verb'\n\n";
    usage(2);
};
exit $run->();

# ---------------------------------------------------------------------------

sub fail {
    print {*STDERR} "lazysite-handlers: $_[0]\n";
    exit 2;
}

# Who the write is made as, as the handler contract's authority check reads it.
sub who {
    my $actor = $opt{actor};
    fail( '--actor is required for a write. There is no session behind a shell: name the '
            . 'account the change is made AS, and it gets exactly the authority that account '
            . 'has in the manager (`local` is the break-glass identity).' )
        unless defined $actor && length $actor;
    return ( unconstrained => 1 ) if $actor eq 'local';
    return ( caps          => Lazysite::Auth::Settings::caps_for($actor) || {} );
}

sub emit {
    my ( $r, $human ) = @_;
    if ( $opt{json} ) {
        print JSON::PP->new->canonical->pretty->encode($r);
        return $r->{ok} ? 0 : 1;
    }
    unless ( $r->{ok} ) {
        print {*STDERR} 'refused: ' . ( $r->{error} // 'unknown error' ) . "\n";
        return 1;
    }
    $human->($r) if $human;
    return 0;
}

# --set key=value, repeated: the fields of a handler or an entry.
sub fields {
    my %f;
    for my $kv ( @{ $opt{set} } ) {
        fail("--set wants key=value (got '$kv')") unless $kv =~ /\A([A-Za-z_]\w*)=(.*)\z/s;
        $f{$1} = $2;
    }
    return \%f;
}

sub cmd_list {
    return emit( Lazysite::Handlers::action_handler_list(), sub {
            my ($r) = @_;
            print "No handlers.\n" unless @{ $r->{handlers} };
            for my $h ( @{ $r->{handlers} } ) {
                my @use = ( map( { "form:$_" } @{ $h->{used_by}{forms} } ),
                    map( { "schedule:$_" } @{ $h->{used_by}{schedule} } ) );
                printf "%-24s %-10s %-8s %s%s\n", $h->{id}, $h->{type} // '?',
                    ( $h->{enabled} ? 'on' : 'off' ), $h->{name} // '',
                    ( @use ? '  [' . join( ', ', @use ) . ']' : '' );
                print "    ! $h->{problem}\n" if $h->{problem};
            }
    } );
}

sub cmd_save {
    my $id = shift @ARGV // '';
    my $in = fields();
    $in->{id} = $id;
    return emit( Lazysite::Handlers::action_handler_save( $in, who() ),
        sub { print( ( $_[0]{created} ? 'created' : 'updated' ) . " handler $_[0]{id}\n" ) } );
}

sub cmd_delete {
    my $id = shift @ARGV // '';
    return emit( Lazysite::Handlers::action_handler_delete( $id, who() ),
        sub { print "deleted handler $_[0]{id}\n" } );
}

sub cmd_bind {
    my $form = shift @ARGV // '';
    my %who  = who();               # binding is manage_forms: the actor must hold it
    return emit( { ok => 0, error => "binding a form needs the 'manage_forms' permission" } )
        unless $who{unconstrained} || ( $who{caps} || {} )->{manage_forms};
    return emit( Lazysite::Handlers::action_form_targets_save( $form, [@ARGV] ),
        sub { print "$_[0]{form} -> " . ( join( ', ', @{ $_[0]{handlers} } ) || '(nothing)' ) . "\n" } );
}

sub cmd_schedule_list {
    return emit( Lazysite::Handlers::action_schedule_list(), sub {
            my ($r) = @_;
            print "The schedule is empty.\n" unless @{ $r->{schedule} };
            for my $e ( @{ $r->{schedule} } ) {
                printf "%-24s every %-7s -> %-20s %s\n", $e->{id}, $e->{every}, $e->{handler},
                    ( $e->{enabled} ? '' : '(off)' );
                print "    ! $e->{problem}\n" if $e->{problem};
            }
    } );
}

sub cmd_schedule_save {
    my $id = shift @ARGV // '';
    my $in = fields();
    $in->{id}      = $id;
    $in->{payload} = $opt{payload} if defined $opt{payload};
    return emit( Lazysite::Handlers::action_schedule_save( $in, who() ),
        sub { print( ( $_[0]{created} ? 'created' : 'updated' ) . " schedule entry $_[0]{id}\n" ) } );
}

sub cmd_schedule_delete {
    my $id = shift @ARGV // '';
    return emit( Lazysite::Handlers::action_schedule_delete( $id, who() ),
        sub { print "deleted schedule entry $_[0]{id}\n" } );
}

# The upgrade's conversion. Prints what it changed and what it could not, and
# exits 1 when something was left - an upgrade that says "done" over a form
# that no longer delivers would be the silent failure this exists to prevent.
sub cmd_convert {
    my $r = Lazysite::Handlers::convert( dry_run => $opt{dry_run} );
    if ( $opt{json} ) {
        print JSON::PP->new->canonical->pretty->encode($r);
        return ( $r->{ok} && !@{ $r->{left} || [] } ) ? 0 : 1;
    }
    unless ( $r->{ok} ) {
        print {*STDERR} "conversion refused: $r->{error}\n";
        return 1;
    }
    my $pre = $opt{dry_run} ? 'would convert' : 'converted';
    print "handlers: nothing to convert\n" unless @{ $r->{changed} } || @{ $r->{left} };
    print "handlers: $pre - $_\n" for @{ $r->{changed} };
    print {*STDERR} "handlers: NOT converted - $_\n" for @{ $r->{left} };
    return @{ $r->{left} } ? 1 : 0;
}

sub usage {
    my ($code) = @_;
    print <<'USAGE';
Usage: lazysite-handlers.pl <command> --docroot DIR [options]

  list                               the handlers, and what uses each
  save ID --set type=T --set name=N [--set key=value ...] --actor A
                                     create or replace a handler
  delete ID --actor A                delete one (refused while in use)
  bind FORM [HANDLER ...] --actor A  set the handlers a form calls
  schedule-list                      the schedule
  schedule-save ID --set handler=H --set every=SECONDS [--payload JSON] --actor A
  schedule-delete ID --actor A
  convert [--dry-run]                bring old shapes to the handler contract
                                     (an upgrade runs this)

Options: --json for machine output. A write needs --actor: the account it is
made as, with that account's capabilities (`local` is the break-glass identity).
The destination decides: a table handler needs manage_data, a connector handler
manage_connectors, email and file handlers manage_forms.
USAGE
    exit $code;
}

__END__

=head1 NAME

lazysite-handlers.pl - delivery handlers, form bindings and the schedule, from a shell

=head1 SYNOPSIS

  lazysite-handlers.pl list --docroot /var/www/site/public_html
  lazysite-handlers.pl save enquiries --docroot D --actor sjm \
      --set type=table --set name=Enquiries --set table=enquiries \
      --set fields=name=name,email=email,message=body
  lazysite-handlers.pl bind contact enquiries --docroot D --actor sjm
  lazysite-handlers.pl schedule-save nightly --docroot D --actor sjm \
      --set handler=crm --set every=86400 --payload '{"source":"timer"}'
  lazysite-handlers.pl convert --docroot D

=head1 DESCRIPTION

The shell surface of the handler contract (SM842). Every command calls the same
functions as the manager, the control API and MCP.

=cut
