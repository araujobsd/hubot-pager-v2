# Description:
#   webhook endpoint for Pagerduty
#
# Dependencies:
#
# Configuration:
#   PAGERV2_ENDPOINT
#   PAGERV2_ANNOUNCE_ROOM
#
# Commands:
#
# Author:
#   mose

Pagerv2 = require '../lib/pagerv2'
moment = require 'moment'
path = require 'path'

module.exports = (robot) ->

  pagerEndpoint = process.env.PAGERV2_ENDPOINT or '/hook'
  pagerAnnounceRoom = process.env.PAGERV2_ANNOUNCE_ROOM

  robot.brain.data.pagerv2 ?= {
    users: { }
  }
  robot.pagerv2 ?= new Pagerv2 robot, process.env
  pagerv2 = robot.pagerv2

  # Webhook listener
  # console.log robot.adapterName
  if pagerAnnounceRoom?
    robot.router.post pagerEndpoint, (req, res) =>

      if req.body? and req.body.messages? and req.body.messages[0].type?
        robot.logger.debug req.body
        if /^incident.*$/.test(req.body.messages[0].type)
          pagerv2.parseWebhook(robot.adapterName, req.body.messages)
          .then (messages) ->
            for message in messages
              robot.messageRoom pagerAnnounceRoom, message
          .catch (e) ->
            robot.logger.warning e
          res.status(200).end()
        else
          robot.logger.warning '[pagerv2] Invalid hook payload ' +
                               "type #{req.body.messages[0].type} from #{req.ip}"
          res.status(422).end()
      else
        robot.logger.warning "[pagerv2] Invalid hook payload from #{req.ip}"
        res.status(422).end()
