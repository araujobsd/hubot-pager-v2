# Description:
#   handles communication with PagerDuty API v2
#
# Dependencies:
#
# Configuration:
#  PAGERV2_API_KEY
#  PAGERV2_SCHEDULE_ID  # the schedule used for oncall and overrides
#  PAGERV2_OVERRIDERS   # list of user_id that can be targets of overrides
#  PAGERV2_SERVICES     # list of service ids that are watched
#
# Author:
#   mose

https = require 'https'
moment = require 'moment'
Promise = require 'bluebird'
querystring = require 'querystring'

class Pagerv2

  constructor: (@robot) ->
    @robot.brain.data.pagerv2 ?= {
      users: { }
    }
    @pagerServices = { }
    if process.env.PAGERV2_SERVICES?
      for service in process.env.PAGERV2_SERVICES.split(',')
        [code, label] = service.split ':'
        @pagerServices[code] = label
    @logger = @robot.logger
    @logger.debug 'Pagerv2 Loaded'

  getPermission: (user, group) =>
    return new Promise (res, err) =>
      isAuthorized = @robot.auth?.hasRole(user, [group, 'pdadmin']) or
                     @robot.auth?.isAdmin(user)
      if @robot.auth? and not isAuthorized
        err "You don't have permission to do that."
      else
        res()

  request: (method, endpoint, query, from = false) ->
    return new Promise (res, err) ->
      if process.env.PAGERV2_API_KEY?
        auth = "Token token=#{process.env.PAGERV2_API_KEY}"
        body = querystring.stringify(query)
        options = {
          hostname: 'api.pagerduty.com'
          port: 443
          method: method
          path: endpoint
          headers: {
            Authorization: auth
            Accept: 'application/vnd.pagerduty+json;version=2'
          }
        }
        if from?
          options.headers.From = from
        req = https.request options, (response) ->
          data = ''
          response.on 'data', (chunk) ->
            data += chunk
          response.on 'end', ->
            res JSON.parse(data)
        req.end()
        req.on 'error', (error) ->
          err "#{error.code} #{error.message}"
      else
        err 'PAGERV2_API_KEY is not set in your environment.'

  getUser: (from, user) =>
    return new Promise (res, err) =>
      @data = @robot.brain.data.pagerv2
      unless user.id?
        user.id = user.name
      if @data.users[user.id]?.pdid?
        res @data.users[user.id].pdid
      else
        @data.users[user.id] ?= {
          name: user.name,
          id: user.id
        }
        if user.pdid?
          @data.users[user.id].pdid = user.pdid
          res @data.users[user.id].pdid
        else
          email = @data.users[user.id].email or
                  user.email_address
          unless email
            err @_ask_for_email(from, user)
          else
            user = @data.users[user.id]
            query = { 'query': email }
            @request('GET', '/users', query)
            .then (body) =>
              if body.users[0]?
                @robot.brain.data.pagerv2.users[user.id].pdid = body.users[0].id
                res body.users[0].id
              else
                err "Sorry, I cannot find #{email}"

  getUserEmail: (from, user) ->
    return new Promise (res, err) =>
      unless user.id?
        user.id = user.name
      @data = @robot.brain.data.pagerv2
      email = @data.users[user.id].email or user.email_address
      if email?
        res email
      else
        err @_ask_for_email(from, user)

  setUser: (user, email) =>
    return new Promise (res, err) =>
      @data = @robot.brain.data.pagerv2
      unless user.id?
        user.id = user.name
      @data.users[user.id] ?= {
        name: user.name,
        email: email,
        id: user.id
      }
      user = @data.users[user.id]
      query = { 'query': email }
      @request('GET', '/users', query)
      .then (body) =>
        if body.users[0]?
          @robot.brain.data.pagerv2.users[user.id].pdid = body.users[0].id
          res body.users[0].id
        else
          err "Sorry, I cannot find #{email}"

  _ask_for_email: (from, user) ->
    if from.name is user.name
      "Sorry, I can't figure out your email address :( " +
      'Can you tell me with `.pd me as <email>`?'
    else
      if @robot.auth? and (@robot.auth.hasRole(from, ['pdadmin']) or
         @robot.auth.isAdmin(from))
        "Sorry, I can't figure #{user.name} email address. " +
        "Can you help me with `.pd #{user.name} as <email>`?"
      else
        "Sorry, I can't figure #{user.name} email address. " +
        'Can you ask them to `.pd me as <email>`?'

  getSchedule: (fromtime = false, totime = false, schedule_id = process.env.PAGERV2_SCHEDULE_ID) ->
    query = {
      since: fromtime or moment().format(),
      until: totime or moment().add(1, 'minutes').format(),
      time_zone: 'UTC',
      overflow: 'true'
    }
    @request('GET', "/schedules/#{schedule_id}", query)
    .then (body) ->
      body.schedule.final_schedule.rendered_schedule_entries[0]

  getOverride: (schedule_id = process.env.PAGERV2_SCHEDULE_ID) ->
    query = {
      since: moment().format(),
      until: moment().add(1, 'minutes').format(),
      editable: 'true',
      overflow: 'true'
    }
    @request('GET', "/schedules/#{schedule_id}/overrides", query)
    .then (body) ->
      body.overrides


  setOverride: (from, who, duration) ->
    return new Promise (res, err) =>
      if duration > 1440
        err 'Sorry you cannot set an override of more than 1 day.'
      else
        duration = parseInt duration
        schedule_id = process.env.PAGERV2_SCHEDULE_ID
        overriders = process.env.PAGERV2_OVERRIDERS?.split(',')
        if not who? or who is 'me'
          who = { name: from.name }
        else
          if overriders and who not in overriders
            unless @robot.auth? and
               (@robot.auth.hasRole(from, ['pdadmin']) or @robot.auth.isAdmin(from))
              who = null
              err "You cannot force #{who.name} to take the override."
        if who?
          @getUser(from, who)
          .bind({ id: null })
          .then (id) =>
            @id = id
            @getSchedule()
          .then (data) =>
            query  = {
              'start': moment().format(),
              'user': {
                'id': @id,
                'type': 'user_reference'
              }
            }
            if duration?
              query.end = moment().add(duration, 'minutes').format()
            else
              query.end = moment(data.end)
            # TODO - with user on call, res a relevant message
            @request('POST', "/schedules/#{schedule_id}/overrides", query)
            .then (body) ->
              body.override.over = {
                name: who.name
              }
              res body.override
            .catch (error) ->
              err error
          .catch (error) ->
            err error

  dropOverride: (from, who) ->
    return new Promise (res, err) =>
      schedule_id = process.env.PAGERV2_SCHEDULE_ID
      if not who? or who is 'me'
        who = { name: from.name }
      else
        if overriders and who not in overriders
          unless @robot.auth? and
             (@robot.auth.hasRole(from, ['pdadmin']) or @robot.auth.isAdmin(from))
            who = null
            err "You cannot force #{who.name} to take the override."
      if who?
        @getUser(from, who)
        .bind({ id: null })
        .then (id) =>
          @id = id
          @getOverride()
        .then (data) =>
          todo = null
          for over in data
            if over.user.id is @id
              todo = over.id
          if todo?
            @request('DELETE', "/schedules/#{schedule_id}/overrides/#{todo}")
            .then (data) ->
              res data
          else
            res null

  getIncident: (incident) ->
    @request('GET', "/incidents/#{incident}")

  listIncidents: (incidents = '', statuses = 'triggered,acknowledged') ->
    if incidents isnt ''
      new Promise (res, err) ->
        res {
          incidents: incidents.split(/, ?/).map (inc) ->
            { id: inc }
          }
    else
      query = {
        date_range: 'all',
        time_zone: 'UTC'
      }
      if statuses?
        query.statuses = statuses.split /,/
      @request('GET', '/incidents', query)

  updateIncidents: (user, incidents = '', which = 'triggered', status = 'acknowledged') ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .then (email) =>
      @from = email
      @listIncidents incidents, which
    .then (data) =>
      if data.incidents.length > 0
        payload = {
          incidents: []
        }
        for inc in data.incidents
          payload.incidents.push {
            id: inc.id,
            type: 'incident_reference',
            status: status
          }
        @request('PUT', '/incidents', payload, @from)
      else
        "There is no #{which} incidents at the moment."

  assignIncidents: (user, who, incidents = '') ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .bind({ assignees: null })
    .then (email) =>
      @from = email
      assigneesDone = Promise.map who.split(/, ?/), (assignee) =>
        @getUser(user, { name: assignee })
      Promise.all assigneesDone
    .then (assignees) =>
      @assignees = assignees
      @listIncidents incidents
    .then (data) =>
      if data.incidents.length > 0
        payload = {
          incidents: []
        }
        for inc in data.incidents
          payload.incidents.push {
            id: inc.id,
            type: 'incident_reference',
            assignments: []
          }
          for a in @assignees
            payload.incidents.push {
              id: a,
              type: 'user_reference'
            }
        @request('PUT', '/incidents', payload, @from)
      else
        "There is no #{which} incidents at the moment."

  snoozeIncidents: (user, incidents = '', duration = 120) ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .then (email) =>
      @from = email
      @listIncidents incidents
    .then (data) =>
      if data.incidents.length > 0
        incidentsDone = Promise.map data.incidents, (inc) =>
          payload = {
            duration: duration
          }
          @request('POST', "/incidents/#{inc.id}/snooze", payload, @from)
        Promise.all incidentsDone
      else
        "There is no #{which} incidents at the moment."

  addNote: (user, incident, note) ->
    @getUserEmail(user, user)
    .then (email) =>
      payload = {
        note: {
          content: note
        }
      }
      @request('POST', "/incidents/#{incident}/notes", payload, @from)

  listNotes: (incident) ->
    @request('GET', "/incidents/#{incident}/notes")

  listMaintenances: ->
    query = {
      filter: 'ongoing'
    }
    @request('GET', '/maintenance windows', query)



module.exports = Pagerv2
