#---------------------------------------------------------------------
package PostScript::ScheduleGrid::XMLTV;
#
# Copyright 2011 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 8 Oct 2011
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Create a printable TV listings grid from XMLTV data
#---------------------------------------------------------------------

use 5.010;
use Moose;

our $VERSION = '0.01';
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

use Moose::Util::TypeConstraints qw(duck_type);
use MooseX::Types::DateTime (); # Just load coercions
use MooseX::Types::Moose qw(ArrayRef Bool CodeRef HashRef Int Str);

use DateTime::Format::XMLTV;
use Encode qw(find_encoding);
use List::Util qw(min);
use PostScript::ScheduleGrid;
use XMLTV 0.005 qw(best_name);

use namespace::autoclean;

#=====================================================================

=attr start_date

This is the date and time at which the listings will begin.  Required.

=attr end_date

This is the date and time at which the listings will end.  Required.

=cut

has start_date => (
  is       => 'ro',
  isa      => 'DateTime',
  required => 1,
);

has end_date => (
  is       => 'ro',
  isa      => 'DateTime',
  required => 1,
);

=attr channels

This is a hashref containing the schedule data.  You don't normally
deal directly with this; it's assembled from the XMLTV data.  For
advanced tasks, you could manipulate this hash between parsing the
listings and calling the C<grid> method.

=cut

has channels => (
  is      => 'ro',
  isa     => HashRef,
  default => sub { {} },
);

=attr channel_settings

This is a hashref that allows you to override the default
configuration for a channel.  The key is either the channel ID
assigned by XMLTV (e.g. C<I10183.labs.zap2it.com>) or its default
display name (e.g. S<C<285 EWTN>>).  The value is merged with the
default channel settings when creating entries in the C<channels>
hash.  Keys you might want to include are:

=over

=item name

The channel name as it should appear in the grid.  By default, taken
from the XMLTV C<display-name>.

=item Number

This controls the order in which channels appear in the grid.  They
are sorted in ascending order by C<Number> (note the capitalization).
Defaults to the first string of digits in the XMLTV C<display-name>.

=item lines

The number of lines that should be used for program listings.  Defaults
to the C<lines_per_channel> attribute.

=back

=cut

has channel_settings => (
  is      => 'ro',
  isa     => HashRef[HashRef],
  default => sub { {} },
);

=attr lines_per_channel

The number of lines that should be used for program listings
(default 2).  Can be overriden on a per-channel basis through the
C<channel_settings> attribute.

=cut

has lines_per_channel => (
  is      => 'ro',
  isa     => Int,
  default => 2,
);

=attr program_callback

An optional CodeRef that will be called for each program occurrence.
It receives a single hashref containing data about this occurrence,
and can modify that hashref to alter the way the program will appear
in the grid.  The keys are:

=over

=item show **

The title of the program.

=item episode **

The title of the episode.  Will be appended to C<show> following a
colon.

=item part **

If this is a multi-part episode, a string like C<(1/2)>, otherwise
C<undef>.  This will be appended to C<show> preceded by a space (after
appending C<episode>, if any).

=item category **

The category name for PostScript::ScheduleGrid.

=item start **

The time at which the program begins.

=item stop **

The time at which the program is over.

=item channel

A reference to the entry in C<channels> for the channel the program is
appearing on.

=item dd_progid

For US listings from Schedules Direct, the C<dd_progid> identifying
the episode.

=item xml

The raw XMLTV data structure containing the information about this
program occurrence.

=item parser

The PostScript::ScheduleGrid::XMLTV object that is parsing the data.

=back

The keys identified with ** may be modified by the callback.  (Note: while
you I<can> modify the start & stop times, you probably shouldn't.)

=cut

has program_callback => (
  is      => 'ro',
  isa     => CodeRef,
);

=attr languages

This is an arrayref of language codes identifying your prefered
languages (as used by XMLTV's C<best_name> function).  By default,
it's taken from C<$ENV{LANG}>, or C<en> if that doesn't begin with a
language code.

=cut

has languages => (
  is      => 'ro',
  isa     => ArrayRef[Str],
  default => sub {
    if (($ENV{LANG} // '') =~ /^([[:alpha:]]{2}(?:_[[:alpha:]]{2})?)\b/) {
      [ $1 ]
    } else { [ 'en' ] }
  }, # end default languages
);

#---------------------------------------------------------------------
has _encoding => (
  is      => 'rw',
  isa     => duck_type(['decode']),
);

sub _encoding_cb
{
  my ($self, $name) = @_;
  $self->_encoding(find_encoding($name) or die "Unknown encoding $name");
}

=method decode

  $decoded_text = $tv->decode($text);

This method decodes C<$text> using the encoding specified by XMLTV.
May be used by C<program_callback>.

=cut

sub decode
{
  # decode leaves undef unchanged
  shift->_encoding->decode(shift, Encode::FB_CROAK);
} # end decode
#---------------------------------------------------------------------

=method get_text

  $decoded_text = $tv->get_text(\@choices, [$specific]);

This method picks the best available language from the pairs in
C<@choices> using XMLTV's C<best_name> function and returns that
string after decoding it.  It gets the list of languages to look for
from the C<languages> attribute.

If the optional parameter C<$specific> is defined, then only an exact
match to that language will be returned.  It will return C<undef> if
an exact match is not found.

=cut

sub get_text
{
  my ($self, $choices, $specific) = @_;

  return undef unless $choices;

  if (defined $specific) {
    foreach my $c (@$choices) {
      return $self->decode($c->[0]) if $c->[1] eq $specific;
    }
  } else {
    my $best = best_name($self->languages, $choices);
    return $self->decode($best->[0]) if $best;
  }

  return undef;
} # end get_text

#---------------------------------------------------------------------
sub _channel_cb
{
  my ($self, $c) = @_;

  my $xml_id = $self->decode($c->{id});

  my $channel = $self->decode($c->{'display-name'}[0][0]);
  my ($num)   = defined($channel) && ($channel =~ /(\d+)/);

  my $add = $self->channel_settings->{$xml_id};
  my $addName = $self->channel_settings->{$channel // ''};

  $self->channels->{$xml_id} = my $info = {
    name => $channel, Number => $num, lines => $self->lines_per_channel,
    schedule => [],
    ($addName ? %$addName : ()),
    ($add ? %$add : ()),
    Id => $xml_id,
  };

  confess "Channel id $xml_id has no name"   unless defined $info->{name};
  confess "Channel id $xml_id has no number" unless defined $info->{Number};
} # end _channel_cb

#---------------------------------------------------------------------
sub _program_cb
{
  my ($self, $callback, $p) = @_;

  my $chID    = $self->decode($p->{channel});
  my $channel = $self->channels->{$chID};

  my $id = $self->get_text($p->{'episode-num'}, 'dd_progid');

  confess "Unknown channel $chID for episode $id" unless defined $channel;

  my %p = (
    channel   => $channel,
    dd_progid => $id,
    show      => $self->get_text($p->{title}),
    episode   => $self->get_text($p->{'sub-title'}),
    category  => '',
    xml       => $p,
    parser    => $self,
    (map { $_ => DateTime::Format::XMLTV->parse_datetime($p->{$_}) }
         qw(start stop)),
  );

  return if $p{stop} < $self->start_date or $p{start} > $self->end_date;

  if (defined($id) and $id =~ m!\.(\d+)/(\d+)$!) {
    $p{part} = sprintf '(%d/%d)', $1+1, $2;
  } # end if multi-part episode

  $callback->(\%p) if $callback;

  $p{show} .= ": $p{episode}" if defined $p{episode} and length $p{episode};
  $p{show} .= " $p{part}"     if defined $p{part}    and length $p{part};

  push @{ $channel->{schedule} }, [
    @p{qw(start stop show)},
    $p{category} ? $p{category} : (),
  ];
} # end _program_cb

#---------------------------------------------------------------------
sub _callbacks
{
  my $self = shift;

  my $program_callback = $self->program_callback;

  my $encoding = $self->can('_encoding_cb');
  my $channel  = $self->can('_channel_cb');
  my $program  = $self->can('_program_cb');

  return (
    sub { $encoding->($self, @_) },
    undef,
    sub { $channel->($self, @_) },
    sub { $program->($self, $program_callback, @_) },
  );
} # end _callbacks
#---------------------------------------------------------------------

=method parsefiles

  $tv->parsefiles($filename, ...);

This method parses one or more XMLTV data files, adding the program
listings to the schedule.  It returns the C<$tv> object, so you can
chain method calls.

=cut

sub parsefiles
{
  my $self = shift;

  &XMLTV::parsefiles_callback($self->_callbacks, @_); # stupid prototype

  return $self;
} # end parsefiles
#---------------------------------------------------------------------

=method parse

  $tv->parse($xmltv_document);

This method parses XMLTV data contained in a string, adding the program
listings to the schedule.  It returns the C<$tv> object, so you can
chain method calls.

=cut

sub parse
{
  my $self = shift;

  &XMLTV::parse_callback(shift, $self->_callbacks);# stupid prototype

  return $self;
} # end parse
#---------------------------------------------------------------------

=method grid

  $grid = $tv->grid(...);

This method constructs and returns a PostScript::ScheduleGrid object
using the supplied parameters and the current listings data.  It may
only be called once.

You may pass any parameters that are accepted by the
PostScript::ScheduleGrid constructor, either in a single hashref, or
as a list of S<C<< key => value >>> pairs.

=cut

has _grid_built => (
  is      => 'rw',
  isa     => Bool,
);

sub grid
{
  my $self = shift;

  confess "You can only call 'grid' once" if $self->_grid_built;
  $self->_grid_built(1);

  my $channels = $self->channels;

  PostScript::ScheduleGrid->new(
    resource_title => 'Channel', # FIXME
    resources => [ sort { $a->{Number} <=> $b->{Number} } values %$channels ],
    start_date => $self->start_date,
    end_date   => $self->end_date,
    (@_ == 1) ? %{ $_[0] } : @_
  );
} # end grid

#=====================================================================
# Package Return Value:

__PACKAGE__->meta->make_immutable;
1;

__END__

=head1 SYNOPSIS

  use PostScript::ScheduleGrid::XMLTV;
