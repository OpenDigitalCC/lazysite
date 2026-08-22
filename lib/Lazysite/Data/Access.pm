package Lazysite::Data::Access;

# SM476: who may read a table's rows.
#
# WHAT WENT WRONG WITHOUT THIS. A page bound to a table inherits the PAGE's
# gate, so an operator who put a table behind a gated section tested the page,
# watched it refuse, and reasonably concluded the data was protected. It was
# not: `/cgi-bin/lazysite-data.pl?table=<name>` is a SECOND DOOR to the same
# rows, reached by its own URL, and it inherited nothing from the first. Every
# declared table was readable by anyone who knew its name.
#
# TWO CONTROLS, DELIBERATELY SEPARATE, because they answer different questions
# and an operator gets one of them wrong at a time:
#
#   `public:` in the descriptor  - may an ANONYMOUS visitor see these rows?
#                                  DEFAULT FALSE. A table is a store, not a
#                                  published artefact; a file under the docroot
#                                  is there because you put it there to serve
#                                  it, and a table is not.
#
#   the read list in acls.json   - which named accounts and groups may see
#                                  them. Same store, same shape and same
#                                  semantics as a file's ACL: entries are
#                                  `username` or `@group`, no entry means no
#                                  restriction, and the site-wide rule applies
#                                  when nothing more specific does.
#
# THE TWO COMPOSE WITHOUT EITHER OVERRIDING THE OTHER, and the awkward case
# falls out rather than being special-cased: a table marked public that ALSO
# carries a read list refuses an anonymous visitor, because an anonymous
# visitor matches no entry in a list and `_acl_allows` already returns false
# for exactly that reason. Nothing here has to know it is a special case.
#
# THE ACL KEY IS THE DESCRIPTOR'S OWN PATH, `lazysite/db/tables/<name>`, and
# that is not cosmetic. ACL lookup is longest-prefix, so an operator can govern
# every table at once with a rule on `lazysite/db/tables`, and a site-wide
# private rule covers tables the same way it covers pages - both for free, from
# the existing matcher, with no table-shaped concept added to it. It cannot
# collide with a content rule either: `lazysite/` is the engine directory and
# never holds content.
#
# THERE IS NO OPERATOR BYPASS ON A VISITOR SURFACE, and that is a decision
# rather than an omission. A page renders the same rows for an operator as for
# a visitor - which is what SM466 exists to guarantee for layouts and themes,
# and is the only way a preview means anything. An operator reads their data in
# the manager, over MCP or through the API, all of which are gated by
# `manage_data` and are `as => 'operator'` here.

use strict;
use warnings;
use Exporter 'import';

# IMPORTED, not called as Lazysite::Auth::Acl::_acl_allows(...). It is in that
# module's @EXPORT_OK and lazysite-dav.pl reaches it the same way; perlcritic
# refuses the fully-qualified form as a private call, and is right to - the
# export list is the statement that this one is meant to be shared.
#
# ADR 0001, AND WHY THIS MAY LOAD A MODULE AT ALL. The processor's render path
# is module-free, which is why it carries its OWN copy of this decision as
# _acl_allows_read (t/lint/36 pins the two together). This module is reached
# only through Tables.pm, which resolve_db already loads lazily as a per-page
# opt-in - so a site with no `db:` binding loads none of it, and the property
# holds for that site exactly as it did before.
use Lazysite::Auth::Acl qw(_acl_allows);

our @EXPORT_OK = qw(may_read acl_key);

sub acl_key { return "lazysite/db/tables/$_[0]" }

# $as is either the string 'operator' - a caller that has already been gated by
# manage_data - or a hashref { user, groups }. Anything else is a caller that
# has not said who is asking, and the answer to that is no.
sub may_read {
    my ( $docroot, $desc, $as ) = @_;

    return 1 if defined $as && !ref $as && $as eq 'operator';
    return 0 unless ref $as eq 'HASH';

    my $user   = $as->{user}   // '';
    my $groups = $as->{groups} // [];
    $groups = [] unless ref $groups eq 'ARRAY';

    # THE PUBLICATION GATE. An anonymous visitor sees nothing that has not been
    # published, whatever the ACL says - so forgetting to write an ACL cannot
    # expose a table, which is the failure mode that matters when the person
    # forgetting is in a hurry.
    return 0 if !$desc->{public} && !length $user;

    local $Lazysite::Auth::Acl::DOCROOT     = $docroot;
    local @Lazysite::Auth::Acl::user_groups = @{$groups};
    return _acl_allows( acl_key( $desc->{table} ),
        'read', ( length $user ? $user : undef ) ) ? 1 : 0;
}

1;
