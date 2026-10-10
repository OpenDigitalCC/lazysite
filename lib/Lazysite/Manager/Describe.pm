package Lazysite::Manager::Describe;

# Introspection: what the site provides (site_capabilities), what an account may
# do (describe-capabilities, the capability map) and what it may call
# (actions-list), with what each action does (_action_effects). Moved unchanged
# out of lazysite-manager-api.pl by SM944 S25.
#
# Index
#   site_capabilities             the `provides` of enabled plugins (whoami reads it)
#   action_describe_capabilities  describe-capabilities: the map, for an account
#   action_actions_list           actions-list: what an account may call
#   _json_bool                    one spelling of a JSON boolean (whoami reads it)
#   _action_effects               mutating / destructive / changes_access
#
# The request context ($token_auth) is read from Lazysite::Manager::Common, which
# lazysite-manager-api.pl sets and nothing here assigns (t/lint/217). Loaded
# where no request set it, both actions refuse: no account is asking
# (t/unit/manager/205). $DOCROOT is set by the dispatcher, as for every manager
# module.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                      ();
use Lazysite::Capabilities        qw(describe);
use Lazysite::Auth::Settings      ();
use Lazysite::ControlApi::Actions ();
use Lazysite::Manager::Plugins    qw(action_plugin_list);
use Lazysite::Manager::Common     qw($token_auth users_api);

our @EXPORT_OK = qw(site_capabilities action_describe_capabilities action_actions_list _json_bool);

our $DOCROOT;    # set by the script

# What _action_effects publishes, derived from the tables the gates enforce, as
# lazysite-manager-api.pl derives its own copies for those gates (its comments
# above %MUTATING, %DESTRUCTIVE and %CHANGES_ACCESS say what each is). The same
# functions, so the same answer; constants, filled when the module loads.
my %MUTATING       = Lazysite::ControlApi::Actions::mutating();
my %DESTRUCTIVE    = Lazysite::ControlApi::Actions::destructive();
my %CHANGES_ACCESS = Lazysite::ControlApi::Actions::changes_access();

# SM072: capabilities the site provides, collected from the `provides`
# field of ENABLED plugins (e.g. form-smtp provides 'email-send'). Lets
# other code detect whether the site can, say, send email.
sub site_capabilities {
    my %caps;
    my $pl = action_plugin_list() || {};
    for my $p ( @{ $pl->{plugins} || [] } ) {
        next unless $p->{_enabled} && ref $p->{provides} eq 'ARRAY';
        $caps{$_} = 1 for @{ $p->{provides} };
    }
    return [ sort keys %caps ];
}

# SM072: agent introspection. Returns the CALLER's grant (capabilities,
# groups, scope) and what the site offers (plugins with status, layouts and
# themes with their active flags) - so an agent learns its real grant rather
# than parsing the bootstrap prose. Allowed for any authenticated caller.
# SM126: the capability map - the static model (channels, what each capability
# unlocks, task recipes, engine-owned paths) plus this caller's own grant under
# "holds". Introspection: allowed for any authenticated caller (token or cookie).
sub action_describe_capabilities {
    my ($user) = @_;
    # SM944 S25 (a), ruled 2026-10-10: THE MAP IS AN ACCOUNT'S. Inside a request
    # the dispatcher has refused an empty $auth_user before any action runs, so
    # $user is never empty here; reached outside one (the request context's
    # reset leaves nobody) it answered ok:1 for account '' - the capability map,
    # the site's documentation index and every action's effects
    # (tmp/sm944-s25-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'The capability map is described for a signed-in account, and no account is asking.' }
        unless length( $user // '' );
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    my $allg   = ( users_api( { action => 'groups' } ) || {} )->{groups} || {};
    my @groups = sort grep {
        ref $allg->{$_} eq 'ARRAY' && ( grep { $_ eq $user } @{ $allg->{$_} } )
    } keys %$allg;
    my $map = describe( caps => $s, account => $user, groups => \@groups,
        display_name => Lazysite::Auth::Settings::display_name_for($user),
        docroot      => $DOCROOT );    # SM225: include the documentation index
        # SM572: per action, whether it mutates and whether it is destructive -
        # every registered action, whoever asks, because this is the map.
        # SM779: and which CHANNEL serves it. The map listed `users` beside
        # `data-rows` with nothing to tell a token client that one of them is
        # cookie-only, while the refusal it met sent it to this very document.
        # `cookie_only` is the same fact actions-list already publishes.
    $map->{actions} = {
        map {
            $_ => { %{ _action_effects($_) },
                ( defined $Lazysite::ControlApi::Actions::ACTION{$_}{caps} ? () : ( cookie_only => JSON::PP::true() ) ) }
        } keys %Lazysite::ControlApi::Actions::ACTION
    };
    $map->{ok} = 1;
    return $map;
}

# SM350: the control API's answer to tools/list.
#
# describe-capabilities says what this account MAY DO in capability terms; this
# says what it may CALL, with the parameters each takes and where each is read
# from. The two were meant to be read together and only one of them existed.
#
# Subset by grant, exactly as tools/list does (SM210). A reference listing every
# action regardless would be a list of things to try and be refused, which is
# what an agent does with it - the refusals then look like defects.
#
# The cookie/token distinction is passed rather than inferred, because it is the
# one thing that decides availability for 59 of the 111 actions and the module
# has no business reading the request.
sub action_actions_list {
    my ($user) = @_;
    # SM944 S25 (b), ruled 2026-10-10: THE LIST IS AN ACCOUNT'S. Inside a request
    # the dispatcher has refused an empty $auth_user before any action runs, so
    # $user is never empty here; reached outside one (the request context's
    # reset leaves nobody) it answered ok:1 for account '' on the token channel
    # with the actions a grant of nothing may call (tmp/sm944-s25-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'The actions list is for a signed-in account, and no account is asking.' }
        unless length( $user // '' );
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    return {
        ok      => 1,
        account => $user,
        channel => ( $token_auth ? 'token' : 'cookie' ),
        actions => [
            map { my %row = ( %$_, %{ _action_effects( $_->{action} ) } ); \%row }
                @{ Lazysite::ControlApi::Actions::actions_for( $s, cookie => ( $token_auth ? 0 : 1 ) ) }
        ],
    };
}

# SM572: what an action DOES, from the tables the gates already enforce.
# `mutating` is %MUTATING (the POST/CSRF gate) and `destructive` is the
# drop/delete/rebuild family, so a caller can skip writers by declaration
# rather than by memory.
# SM587: and `changes_access` is the second axis - what happens to the data and
# what happens to who can read it are two questions, answered here together.
# Both optional keys are emitted only when true, so a listing stays readable
# and an absent key means the same thing as false.
# JSON booleans for the whoami payload and the language block beneath it -
# one spelling, so the two emitters cannot drift.
sub _json_bool { return $_[0] ? JSON::PP::true() : JSON::PP::false() }

sub _action_effects {
    my ($name) = @_;
    return {
        mutating => ( $MUTATING{$name} ? JSON::PP::true() : JSON::PP::false() ),
        ( $DESTRUCTIVE{$name}    ? ( destructive => JSON::PP::true() )    : () ),
        ( $CHANGES_ACCESS{$name} ? ( changes_access => JSON::PP::true() ) : () ),
    };
}

1;
