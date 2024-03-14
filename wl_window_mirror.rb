#!/usr/bin/ruby
#
# WlWindowMirror
# Copyright (C) 2024 Will Stephenson
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# frozen_string_literal: true

require 'dbus'
require 'gst'

# Displays a video stream captured from a Wayland window in another window.
# You could also view setup stream externally with gst-launch if desired:
# > gst-launch-1.0 pipewiresrc path=<pipewire-node-id> !  videoconvert ! autovideosink

class WlWindowMirror
  def initialize
    logger.level = Logger::DEBUG

    @debug_objects = false

    # get the bus object
    @bus = DBus::SessionBus.instance

    @portal = nil

    @desktop_portal_service = @bus.service('org.freedesktop.portal.Desktop')
    @portal = @desktop_portal_service.object('/org/freedesktop/portal/desktop')
    @portal.default_iface = 'org.freedesktop.portal.ScreenCast'

    @session = nil

    @loop = nil
  end

  # Portal DBUS methods
  def CreateSession
    portal_call(__method__.to_s, { 'session_handle_token' => create_token }) do |results|
      @session = @desktop_portal_service.object(results['session_handle'])
      dump_object(__method__.to_s, @session)
      session_iface = @session['org.freedesktop.portal.Session']

      session_iface.on_signal('Closed') do |details|
        logger.info "Session Closed. - #{details}"
        @loop&.quit
        @session = nil
      end
    end
  end

  def SelectSources
    # types = 2 => only offer windows, see AvailableSourceTypes here
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html#org-freedesktop-portal-screencast-selectsources
    # explicit typing necessary here because the variant dict type of 'options' in the method signature gives
    # the dbus gem no clue what type to marshall the ruby integer '2' to (needs u, gets i otherwise)
    portal_call(__method__.to_s, @session, { 'types' => DBus::Data::UInt32.new(2) }) do
      logger.debug "#{__method__} succeeded"
    end
  end

  def Start
    portal_call(__method__.to_s, @session, '', {}) do |results|
      @pipewire_node_id = results['streams'].first[0]
      stream_properties = results['streams'].first[1]
      logger.info '********* Session started successfully ********'
      logger.info "Pipewire node ID: #{@pipewire_node_id}"
      logger.debug "Stream properties: #{stream_properties}"
      logger.info '*********'
    end
  end

  def Close
    @session&.Close
  end

  # Utility methods
  def start_gstreamer
    bin = Gst::Pipeline.new('pipeline')
    src = Gst::ElementFactory.make('pipewiresrc', nil) || raise('need gstreamer-plugin-pipewire')
    src.path = @pipewire_node_id.to_s
    cnv = Gst::ElementFactory.make('videoconvert', nil)
    sink = Gst::ElementFactory.make('autovideosink', nil)

    bin << src << cnv << sink
    src >> cnv >> sink
    bin.play
  end

  def wait_for_exit
    unless @loop
      @loop = DBus::Main.new
      @loop << @bus
    end
    @loop.run
  end

  protected

  # Instead of simply returning an asynchronous result, portal methods return the object path to a Request object,
  # which itself emits a Response signal when the result is ready. This is because the user interaction with the portal
  # UI may exceed the dbus async call timeout.
  # Wraps the initial call and the request signal handler with
  # an inner event loop.
  # The block `handler` is called with the final results received by via signal.
  # Ihe 'handle_token' value is added to the options hash in `args` transparently
  def portal_call(method_name, *args, &handler)
    loop = DBus::Main.new
    loop << @bus
    # insert the request handle token into the options hash, because that is internal to this helper
    request_handle_token = create_token
    # this is wobbly and only works because the portal methods all only take one hash
    options = args.select { |a| a.is_a?(Hash) }.first
    options['handle_token'] = request_handle_token

    # make it cleaner to pass args of type o, just pass the object or a string
    args.map! { |a| a.is_a?(DBus::ProxyObject) ? a.path : a }

    responses = @portal.send(method_name, *args)
    request_handle_returned = responses.first

    unless request_handle_returned == request_object_path(request_handle_token)
      logger.info "! request handle doesn't match supplied token:\n" \
                    "#{request_object_path(request_handle_token)}\n  #{request_handle_returned}"
    end

    # Set up the DBus match for the Response signal prior to getting the Request object path
    # to avoid a race condition:
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html#org-freedesktop-portal-request
    begin
      mr = DBus::MatchRule.new
      mr.type = 'signal'
      mr.interface = 'org.freedesktop.portal.Request'
      mr.member = 'Response'
      mr.path = request_handle_returned

      @bus.add_match(mr) do |msg|
        response = msg.params[0]
        results = msg.params[1]
        begin
          if response.zero?
            handler.call(results)
          else
            logger.warn 'Request failed!!!'
            self.Close
            exit(response)
          end
        ensure
          loop.quit
        end
      end
    rescue DBus::Error => e
      logger.debug e.message
      self.Close
      exit(1)
    end
    loop.run
  end

  def path_safe_unique_name
    @bus.unique_name.tr('.', '_').tr(':', '')
  end

  def create_token
    [*('A'..'Z')].sample(8).join
  end

  def request_object_path(request_handle_token)
    "/org/freedesktop/portal/desktop/request/#{path_safe_unique_name}/#{request_handle_token}"
  end

  def dump_object(method_name, object)
    return unless @debug_objects

    logger.debug "********* #{method_name} (#{object.path}) ********"
    logger.debug object.introspect
    logger.debug '*********'
  end

  def logger
    @logger ||= Logger.new($stderr)
  end
end

app = WlWindowMirror.new
app.CreateSession
app.SelectSources
app.Start

app.start_gstreamer
app.wait_for_exit

app.Close

exit(0)
