#!/usr/bin/perl

# SM289: set and read per-path access from a shell.
#
# WHY THIS EXISTS. Every other administrative act on lazysite has a CLI form,
# because the recovery story for this product is "you have a shell". Access
# control did not: an operator could create users and groups, set channels and
# policies, run the health check and repair permissions - and had no way to grant
# a person access to a path. So the answer to "the manager is locked out and I
# need to grant myself access" was to hand-edit acls.json, which is the exact
# thing SM267 was built to stop people doing.
#
# ONE WRITER, and that is the whole design. This calls
# Lazysite::Manager::Files::action_acl_set - the same function the manager panel,
# the control API and MCP call. A rule written from a shell is therefore the same
# object, governed by the same rules, moved into the private store by the same
# code (SM286), audited the same way. A fourth implementation of the ACL grammar
# would be a fourth place for it to drift.
#
# THE ACTOR IS MANDATORY, and this is the security-critical part of the file.
# Every other surface resolves an authenticated identity and applies the grant
# ceiling; there is no session behind a shell. Defaulting to an operator identity
# would turn a convenience into a privilege-escalation path on the one surface
# with nothing checking it - a user who cannot grant themselves access in the
# manager could simply run this instead. So --actor is required, its groups are
# resolved through the SAME resolver every channel uses (SM288), and the writer's
# own authority checks then apply unchanged.

use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/../lib";
use Getopt::Long ();
use JSON::PP     ();
use Lazysite::Manager::Files
    qw(action_acl_get action_acl_set action_acl_remove action_protected_sections);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();
use Lazysite::Auth::Settings  ();

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';

my %opt = ( docroot => '', actor => '', read => undef, write => undef,
    draft => undef, owner => undef, json => 0 );

Getopt::Long::GetOptions(
    'docroot=s' => \$opt{docroot},
    'actor=s'   => \$opt{actor},
    'read=s'    => \$opt{read},
    'write=s'   => \$opt{write},
    'owner=s'   => \$opt{owner},
    'draft!'    => \$opt{draft},
    'json'      => \$opt{json},
    'help|h'    => sub { usage(0) },
) or usage(2);

usage(0) if $verb eq 'help' || $verb =~ /\A-{0,2}help\z|\A-h\z/;
usage(2) unless length $verb;

fail('--docroot is required')          unless length $opt{docroot};
fail("not a directory: $opt{docroot}") unless -d $opt{docroot};

# SM139: lazysite never writes into a site tree as root. A write here touches
# acls.json AND MOVES CONTENT between two trees, creating directories in the
# private store as it goes - so running it as root leaves root-owned files where
# the CGI must be able to update them, which is the Class-B ownership drift
# SM215 exists to repair. save_acls now matches its directory's owner, but the
# store's directories are made by the move, so refusing is the right answer
# rather than a second safety net.
#
# Reads are allowed as root: they create nothing.
#
# LAZYSITE_CLI_FAKE_ROOT is the same test-only override lazysite-cli.pl uses, and
# like it, only ever makes this MORE restrictive.
if ( ( $> == 0 || $ENV{LAZYSITE_CLI_FAKE_ROOT} )
    && ( $verb eq 'set' || $verb eq 'remove' ) )
{
    fail( "refusing to change access as root.\n"
            . "  A write here creates files in the site tree, and root-owned files\n"
            . "  there are exactly what stops the manager working afterwards (SM139).\n"
            . "  Run it as the site user instead:\n"
            . "    sudo -u SITEUSER lazysite acl $verb ...\n"
            . "  (--actor is a different thing: it names the lazysite ACCOUNT the\n"
            . "  rule is written as, not the unix user running the command.)" );
}

# Context for the shared writer. Exactly what the CGI scripts set, and nothing
# more - if this list ever needs to grow, the writer has gained a dependency the
# other surfaces are also setting, and both should be looked at together.
my $docroot = $opt{docroot};
$docroot =~ s{/+\z}{};
$Lazysite::Manager::Files::DOCROOT  = $docroot;
$Lazysite::Manager::Files::LOCK_DIR = "$docroot/lazysite/cache/locks";
$Lazysite::Manager::Common::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT       = $docroot;

# A CLI caller is never a token client. token_auth suppresses the operator
# bypass, and setting it here would make --actor local behave differently from
# the same person in the manager - which is the opposite of the point.
$Lazysite::Auth::Acl::token_auth = 0;

my %HANDLER = (
    list   => \&cmd_list,
    show   => \&cmd_show,
    set    => \&cmd_set,
    remove => \&cmd_remove,
);
my $handler = $HANDLER{$verb} or do {
    print {*STDERR} "lazysite acl: unknown sub-command '$verb'\n\n";
    usage(2);
};
exit $handler->();

# ---------------------------------------------------------------------------

sub fail {
    print {*STDERR} "lazysite acl: $_[0]\n";
    exit 2;
}

# Resolve who is acting, and refuse rather than guess.
#
# Reads are actor-OPTIONAL, not actor-free. An unprotected path shows without
# one, which keeps the common "what governs this?" question cheap. A PROTECTED
# path does not: who may read a gated section is itself information about that
# section, and the shared reader refuses it for the same reason the manager
# does. cmd_show adds the hint, because "Not the owner of this file" is a true
# answer that does not tell a shell user the one thing they can do about it.
sub require_actor {
    my $actor = $opt{actor};
    fail( '--actor is required for a write. There is no session behind a '
            . 'shell, so this tool will not invent an identity: name the account '
            . 'the rule is being written AS, and it gets exactly the authority '
            . 'that account has in the manager.' )
        unless defined $actor && length $actor;

    # `local` is the documented always-operator identity. Allowed, because
    # break-glass recovery is the reason this tool exists - but only when asked
    # for by name. It is never a default.
    return $actor if $actor eq 'local';

    # No existence check here, deliberately. The auth store's users file is
    # parsed in exactly one place today (the users tool), and adding a second
    # parser to produce a friendlier error is the drift this whole programme has
    # been removing - a second reader of a store is a second thing to be wrong.
    #
    # An unknown actor resolves to no groups, is not an operator, and is refused
    # by the writer's own authority check. That is fail-closed and it is the same
    # answer the manager gives, which is the property that matters more than the
    # wording of the message.
    return $actor;
}

# Put the actor's identity where the shared writer reads it - the same three
# variables the CGI scripts set, with groups from the SAME resolver every
# channel uses (SM288), so "which groups is this account in" has one answer.
sub with_actor {
    my ( $actor, $code ) = @_;
    local $Lazysite::Manager::Files::auth_user = $actor;
    local $Lazysite::Auth::Acl::auth_user      = $actor;
    local @Lazysite::Auth::Acl::user_groups =
        ( $actor eq 'local' ? () : Lazysite::Auth::Acl::groups_for_user($actor) );
    return $code->();
}

sub emit {
    my ($r) = @_;
    if ( $opt{json} ) {
        print JSON::PP->new->canonical->pretty->encode($r);
        return $r->{ok} ? 0 : 1;
    }
    if ( !$r->{ok} ) {
        print {*STDERR} 'refused: ' . ( $r->{error} // 'unknown error' ) . "\n";
        return 1;
    }
    return 0;
}

# Warnings are printed on the human path too. The move into the private store
# can fail while the rule is still stored (SM286), and both outcomes look
# identical from outside - so a silent success here would be the same defect
# this whole programme is about.
sub say_warnings {
    my ($r) = @_;
    return unless ref $r->{warnings} eq 'ARRAY';
    print {*STDERR} "note: $_\n" for @{ $r->{warnings} };
    return;
}

sub subjects {
    my ($v) = @_;
    return undef unless defined $v;
    return [ grep { length } split /\s*,\s*/, $v ];
}

sub cmd_list {
    my $r = with_actor( ( $opt{actor} // '' ), sub {
            return action_protected_sections( $opt{actor} // '', [] );
    } );
    return emit($r) if $opt{json} || !$r->{ok};

    my @s = @{ $r->{sections} || [] };
    unless (@s) {
        print "No protected sections.\n";
        return 0;
    }
    printf "%-34s %-7s %-6s %s\n", 'PATH', 'POLICY', 'PAGES', 'READ';
    for my $s (@s) {
        printf "%-34s %-7s %-6s %s\n",
            ( $s->{site_wide} ? '/ (whole site)' : $s->{prefix} ),
            $s->{policy}, $s->{pages},
            ( @{ $s->{read} || [] } ? join( ',', @{ $s->{read} } ) : '-' );
    }
    return 0;
}

sub cmd_show {
    my $path = shift @ARGV;
    fail('a PATH is required') unless defined $path && length $path;
    my $r = with_actor( ( $opt{actor} // '' ),
        sub { return action_acl_get( $path, $opt{actor} // '' ) } );

    # A refused read with no actor named is almost always the missing --actor,
    # not a real denial. Say so once, rather than leaving a shell user to
    # rediscover it.
    if ( !$r->{ok} && !length( $opt{actor} // '' ) && !$opt{json} ) {
        print {*STDERR} "refused: " . ( $r->{error} // '' ) . "\n";
        print {*STDERR}
            "hint: this path is protected, so reading its rule needs an "
            . "identity too - add --actor USER (or --actor local).\n";
        return 1;
    }
    return emit($r) if $opt{json} || !$r->{ok};

    my $a = $r->{acl};
    unless ( $a && %$a ) {
        print "$r->{path}: no rule - public\n";
        return 0;
    }
    print "$r->{path}\n";
    print '  owner:  ' . ( $a->{owner} // '-' ) . "\n";
    print '  read:   '
        . ( @{ $a->{read} || [] } ? join( ',', @{ $a->{read} } ) : '- (anyone)' ) . "\n";
    print '  write:  '
        . ( @{ $a->{write} || [] } ? join( ',', @{ $a->{write} } ) : '- (anyone)' ) . "\n";
    print '  policy: ' . ( $a->{draft} ? 'draft (404 to the public)' : 'gated' ) . "\n";
    return 0;
}

sub cmd_set {
    my $path  = shift @ARGV;
    my $actor = require_actor();
    fail('a PATH is required (use "/" for the whole site)')
        unless defined $path && length $path;
    fail('nothing to set - give at least one of --read, --write, --owner, --draft/--no-draft')
        unless defined $opt{read}
        || defined $opt{write}
        || defined $opt{owner}
        || defined $opt{draft};

    my $r = with_actor( $actor, sub {
            return action_acl_set( $path, $actor, subjects( $opt{read} ),
                subjects( $opt{write} ), $opt{owner},
                ( defined $opt{draft} ? ( $opt{draft} ? 'true' : 'false' ) : undef ) );
    } );
    say_warnings($r);
    my $rc = emit($r);
    print "set: $r->{path}\n" if !$rc && !$opt{json};
    return $rc;
}

sub cmd_remove {
    my $path  = shift @ARGV;
    my $actor = require_actor();
    fail('a PATH is required') unless defined $path && length $path;

    my $r = with_actor( $actor,
        sub { return action_acl_remove( $path, $actor ) } );
    say_warnings($r);
    my $rc = emit($r);
    if ( !$rc && !$opt{json} ) {
        print $r->{removed}
            ? "removed: $r->{path}\n"
            : "no rule at $r->{path} - nothing to remove\n";
    }
    return $rc;
}

sub usage {
    my ($rc) = @_;
    my $fh = ( $rc // 0 ) == 0 ? *STDOUT : *STDERR;
    print {$fh} <<'USAGE';
Usage: lazysite acl SUBCOMMAND --docroot D [options] [PATH]

Read and set per-path access - the same rules, in the same store, as the
manager, the control API and MCP. A rule written here is identical to one
written there.

Sub-commands:
  list                      the sections currently held back
  show PATH                 the rule governing PATH, if any
  set  PATH --actor USER [--read LIST] [--write LIST] [--owner USER]
                         [--draft | --no-draft]
  remove PATH --actor USER

Options:
  --docroot D    the site's document root (required)
  --actor USER   the account the change is made AS (required for set/remove).
                 The rule is subject to exactly the authority that account has
                 in the manager. Use `local` for break-glass operator access.
  --read  LIST   comma-separated: usernames and @groups. Omit to leave
                 unchanged; an EMPTY list means anyone may read.
  --write LIST   likewise, for editing.
  --draft        hold the section back entirely: 404 to the public, and absent
                 from the sitemap, feeds and search. --no-draft clears it.
  --json         machine-readable output.

PATH is relative to the document root, NOT to a domain's URL - on a
content-rooted domain, /private/notes.pdf is `sites/foo/private`. Use "/" to
govern the whole site.

Setting a read list, or --draft, MOVES the content out of the document root
into the private store; removing the rule moves it back. The whole-site rule
is the exception and moves nothing.
USAGE
    exit( $rc // 0 );
}
