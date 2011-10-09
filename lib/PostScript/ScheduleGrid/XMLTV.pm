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
use MooseX::Types::Moose qw(ArrayRef CodeRef HashRef Int Str);

use DateTime::Format::XMLTV;
use Encode qw(find_encoding);
use List::Util qw(min);
use PostScript::ScheduleGrid;
use XMLTV 0.005 qw(best_name);

use namespace::autoclean;

#=====================================================================

=attr-data start_date

This is the date and time at which the listings will begin.  Required.

=attr-data end_date

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

has channels => (
  is      => 'ro',
  isa     => HashRef,
  default => sub { {} },
);

has channel_settings => (
  is      => 'ro',
  isa     => HashRef,
  default => sub { {} },
);

has lines_per_channel => (
  is      => 'ro',
  isa     => Int,
  default => 2,
);

has program_callback => (
  is      => 'ro',
  isa     => CodeRef,
);

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

sub decode
{
  # decode leaves undef unchanged
  shift->_encoding->decode(shift, Encode::FB_CROAK);
} # end decode

#---------------------------------------------------------------------
sub getText
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
} # end getText

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

  my $id = $self->getText($p->{'episode-num'}, 'dd_progid');

  confess "Unknown channel $chID for episode $id" unless defined $channel;

  my %p = (
    dd_progid => $id,
    show      => $self->getText($p->{title}),
    episode   => $self->getText($p->{'sub-title'}),
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
sub parsefiles
{
  my $self = shift;

  &XMLTV::parsefiles_callback($self->_callbacks, @_);
} # end parsefiles

#---------------------------------------------------------------------
sub parse
{
  my $self = shift;

  &XMLTV::parse_callback(shift, $self->_callbacks);
} # end parse

#---------------------------------------------------------------------
sub grid
{
  my $self = shift;

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

1;

__END__

=head1 SYNOPSIS

  use PostScript::ScheduleGrid::XMLTV;
