require("../../spec_helper")

_            = require("lodash")
chalk        = require("chalk")
cp           = require("child_process")
niv          = require("npm-install-version")
path         = require("path")
http         = require("http")
human        = require("human-interval")
morgan       = require("morgan")
express      = require("express")
Promise      = require("bluebird")
snapshot     = require("snap-shot-it")
debug        = require("debug")("cypress:support:e2e")
httpsProxy   = require("@packages/https-proxy")
Fixtures     = require("./fixtures")
fs           = require("#{root}../lib/util/fs")
allowDestroy = require("#{root}../lib/util/server_destroy")
user         = require("#{root}../lib/user")
cypress      = require("#{root}../lib/cypress")
Project      = require("#{root}../lib/project")
screenshots  = require("#{root}../lib/screenshots")
videoCapture = require("#{root}../lib/video_capture")
settings     = require("#{root}../lib/util/settings")

cp = Promise.promisifyAll(cp)

env = _.clone(process.env)

Promise.config({
  longStackTraces: true
})

e2ePath = Fixtures.projectPath("e2e")
pathUpToProjectName = Fixtures.projectPath("")

DEFAULT_BROWSERS = ['electron', 'chrome']

stackTraceLinesRe = /^(\s+)at\s(.+)/gm
browserNameVersionRe = /(Browser\:\s+)(Custom |)(Electron|Chrome|Canary|Chromium|Firefox)(\s\d+)(\s\(\w+\))?(\s+)/
availableBrowsersRe = /(Available browsers found are: )(.+)/g

replaceStackTraceLines = (str) ->
  str.replace(stackTraceLinesRe, "$1at stack trace line")

replaceBrowserName = (str, key, customBrowserPath, browserName, version, headless, whitespace) ->
  ## get the padding for the existing browser string
  lengthOfExistingBrowserString = _.sum([browserName.length, version.length, _.get(headless, "length", 0), whitespace.length])

  ## this ensures we add whitespace so the border is not shifted
  key + customBrowserPath + _.padEnd("FooBrowser 88", lengthOfExistingBrowserString)

replaceDurationSeconds = (str, p1, p2, p3, p4) ->
  ## get the padding for the existing duration
  lengthOfExistingDuration = _.sum([p2?.length or 0, p3.length, p4.length])

  p1 + _.padEnd("X seconds", lengthOfExistingDuration)

replaceDurationFromReporter = (str, p1, p2, p3) ->
  ## duration='1589'

  p1 + _.padEnd("X", p2.length, "X") + p3

replaceNodeVersion = (str, p1, p2, p3) ->
  ## Node Version: 1.2.3

  return p1 + _.padEnd("X", p2.length, "X") + ' (/foo/bar/node)' + ' '.repeat(p3.length - 16)

replaceDurationInTables = (str, p1, p2) ->
  ## when swapping out the duration, ensure we pad the
  ## full length of the duration so it doesn't shift content
  _.padStart("XX:XX", p1.length + p2.length)

replaceUploadingResults = (orig, match..., offset, string) ->
  results = match[1].split('\n').map((res) ->
    res.replace(/\(\d+\/(\d+)\)/g, '(*/$1)')
  )
  .sort()
  .join('\n')
  ret =  match[0] + results + match[3]

  return ret

normalizeStdout = (str, options = {}) ->
  ## remove all of the dynamic parts of stdout
  ## to normalize against what we expected
  str = str
  .split(pathUpToProjectName)
    .join("/foo/bar/.projects")
  .replace(availableBrowsersRe, "$1browser1, browser2, browser3")
  .replace(browserNameVersionRe, replaceBrowserName)
  .replace(/\s\(\d+([ms]|ms)\)/g, "") ## numbers in parenths
  .replace(/(\s+?)(\d+ms|\d+:\d+:?\d+)/g, replaceDurationInTables) ## durations in tables
  .replace(/(coffee|js)-\d{3}/g, "$1-456")
  .replace(/(.+)(\/.+\.mp4)/g, "$1/abc123.mp4") ## replace dynamic video names
  .replace(/(Cypress\:\s+)(\d\.\d\.\d)/g, "$11.2.3") ## replace Cypress: 2.1.0
  .replace(/(Node Version\:\s+v)(\d+\.\d+\.\d+)( \(.*\)\s+)/g, replaceNodeVersion) ## replace Node Version: 1.2.3
  .replace(/(Duration\:\s+)(\d+\sminutes?,\s+)?(\d+\sseconds?)(\s+)/g, replaceDurationSeconds)
  .replace(/(duration\=\')(\d+)(\')/g, replaceDurationFromReporter) ## replace duration='1589'
  .replace(/\((\d+ minutes?,\s+)?\d+ seconds?\)/g, "(X seconds)")
  .replace(/\r/g, "")
  .replace(/(Uploading Results.*?\n\n)((.*-.*[\s\S\r]){2,}?)(\n\n)/g, replaceUploadingResults) ## replaces multiple lines of uploading results (since order not guaranteed)
  .replace(/^(\- )(\/.*\/packages\/server\/)(.*)$/gm, "$1$3") ## fix "Require stacks" for CI

  str = str.replace(/\(\d{2,4}x\d{2,4}\)/g, "(YYYYxZZZZ)") ## screenshot dimensions

  return str.split("\n")
    .map(replaceStackTraceLines)
    .join("\n")

startServer = (obj) ->
  { onServer, port, https } = obj

  app = express()

  if https
    srv = httpsProxy.httpsServer(app)
  else
    srv = http.Server(app)

  allowDestroy(srv)

  app.use(morgan("dev"))

  if s = obj.static
    opts = if _.isObject(s) then s else {}
    app.use(express.static(e2ePath, opts))

  new Promise (resolve) ->
    srv.listen port, =>
      console.log "listening on port: #{port}"
      onServer?(app, srv)

      resolve(srv)

stopServer = (srv) ->
  srv.destroyAsync()

copy = ->
  ca = process.env.CIRCLE_ARTIFACTS

  debug("Should copy Circle Artifacts?", Boolean(ca))

  if ca
    videosFolder = path.join(e2ePath, "cypress/videos")
    screenshotsFolder = path.join(e2ePath, "cypress/screenshots")

    debug("Copying Circle Artifacts", ca, videosFolder, screenshotsFolder)

    ## copy each of the screenshots and videos
    ## to artifacts using each basename of the folders
    Promise.join(
      screenshots.copy(
        screenshotsFolder,
        path.join(ca, path.basename(screenshotsFolder))
      ),
      videoCapture.copy(
        videosFolder,
        path.join(ca, path.basename(videosFolder))
      )
    )

localItFn = (title, options = {}) ->
  options = _
  .chain(options)
  .clone()
  .defaults({
    only: false,
    onRun: (execFn, browser, ctx) ->
      execFn()
  })
  .value()

  { only, browser, onRun, spec, expectedExitCode } = options

  browser ?= process.env.BROWSER or DEFAULT_BROWSERS

  if not title
    throw new Error('e2e.it(...) must be passed a title as the first argument')

  mochaItFn = if only then it.only else it

  runTestInEachBrowser = (browser) ->
    testTitle = "#{title} [#{browser}]"

    mochaItFn testTitle, ->
      originalTitle = @test.parent.titlePath().concat(title).join(" / ")

      ctx = @

      execFn = (overrides = {}) ->
        e2e.exec(ctx, _.extend({}, options, overrides, {
          browser, originalTitle
        }))

      onRun(execFn, browser, ctx)

  _.chain([])
  .concat(browser)
  .each(runTestInEachBrowser)
  .value()

runAfterEach = (runnable) ->
  Promise.map runnable._afterEach || [], (afterEachHook) ->
    { fn } = afterEachHook

    fn = fn.bind(runnable)

    if fn.length == 1
      return Promise.fromCallback fn

    return fn()
  .then ->
    if runnable.parent
      runAfterEach(runnable.parent)

## eslint-ignore-next-line
localItFn.only = (title, options) ->
  options.only = true
  localItFn(title, options)

module.exports = e2e = {
  normalizeStdout,

  it: localItFn

  snapshot: (args...) ->
    args = _.compact(args)

    ## grab the last element in index
    index = args.length - 1

    ## normalize the stdout of it
    args[index] = normalizeStdout(args[index])

    snapshot.apply(null, args)

  setup: (options = {}) ->
    if npmI = options.npmInstall
      before ->
        ## npm install needs extra time
        @timeout(human("2 minutes"))

        cp.execAsync("npm install", {
          cwd: Fixtures.path("projects/e2e")
          maxBuffer: 1024*1000
        })
        .then ->
          if _.isArray(npmI)

            copyToE2ENodeModules = (module) ->
              fs.copyAsync(
                path.resolve("node_modules", module), Fixtures.path("projects/e2e/node_modules/#{module}")
              )

            Promise
            .map(npmI, niv.install)
            .then ->
              Promise.map(npmI, copyToE2ENodeModules)

        .then ->
          ## symlinks mess up fs.copySync
          ## and bin files aren't necessary for these tests
          fs.removeAsync(Fixtures.path("projects/e2e/node_modules/.bin"))

      after ->
        ## now cleanup the node modules after because these add a lot
        ## of copy time for the Fixtures scaffolding
        fs.removeAsync(Fixtures.path("projects/e2e/node_modules"))

    beforeEach ->
      ## after installing node modules copying all of the fixtures
      ## can take a long time (5-15 secs)
      @timeout(human("2 minutes"))

      Fixtures.scaffold()

      sinon.stub(process, "exit")

      Promise.try =>
        if servers = options.servers
          servers = [].concat(servers)

          Promise.map(servers, startServer)
          .then (servers) =>
            @servers = servers
        else
          @servers = null
      .then =>
        if s = options.settings
          settings.write(e2ePath, s)

    afterEach ->
      process.env = _.clone(env)

      @timeout(human("2 minutes"))

      Fixtures.remove()

      if s = @servers
        Promise.map(s, stopServer)

  options: (ctx, options = {}) ->
    _.defaults(options, {
      browser: 'electron'
      project: e2ePath
      timeout: if options.exit is false then 3000000 else 120000
      originalTitle: null
    })

    ctx.timeout(options.timeout)

    if spec = options.spec
      ## normalize into array and then prefix
      specs = spec.split(',').map (spec) ->
        return spec if path.isAbsolute(spec)

        path.join(options.project, "cypress", "integration", spec)

      ## normalize the path to the spec
      options.spec = specs.join(',')

    return options

  args: (options = {}) ->
    args = [
      ## hides a user warning to go through NPM module
      "--cwd=#{process.cwd()}",
      "--run-project=#{options.project}"
    ]

    if options.spec
      args.push("--spec=#{options.spec}")

    if options.port
      args.push("--port=#{options.port}")

    if options.headed
      args.push("--headed")

    if options.record
      args.push("--record")

    if options.parallel
      args.push("--parallel")

    if options.group
      args.push("--group=#{options.group}")

    if options.ciBuildId
      args.push("--ci-build-id=#{options.ciBuildId}")

    if options.key
      args.push("--key=#{options.key}")

    if options.reporter
      args.push("--reporter=#{options.reporter}")

    if options.reporterOptions
      args.push("--reporter-options=#{options.reporterOptions}")

    if browser = (options.browser)
      args.push("--browser=#{browser}")

    if options.config
      args.push("--config", JSON.stringify(options.config))

    if options.env
      args.push("--env", options.env)

    if options.outputPath
      args.push("--output-path", options.outputPath)

    if options.exit?
      args.push("--exit", options.exit)

    if options.inspectBrk
      args.push("--inspect-brk")

    return args

  start: (ctx, options = {}) ->
    options = @options(ctx, options)
    args    = @args(options)

    cypress.start(args)
    .then ->
      if (code = options.expectedExitCode)?
        expect(process.exit).to.be.calledWith(code)

  exec: (ctx, options = {}) ->
    options = @options(ctx, options)
    args    = @args(options)

    ## if the current test wasn't meant to run in the current browser, skip it
    if (b = process.env.BROWSER) and b isnt options.browser
      console.log(chalk.cyan("This test is meant to run in #{chalk.green(options.browser)}, but process.env.BROWSER is #{chalk.green(b)}. Skipping..."))

      return runAfterEach(ctx._runnable).then ->
        ctx.skip()

    args = ["index.js"].concat(args)

    stdout = ""
    stderr = ""

    exit = (code) ->
      if (expected = options.expectedExitCode)?
        expect(code).to.eq(expected, "expected exit code")

      ## snapshot the stdout!
      if options.snapshot
        ## enable callback to modify stdout
        if ostd = options.onStdout
          stdout = ostd(stdout)

        ## if we have browser in the stdout make
        ## sure its legit
        if matches = browserNameVersionRe.exec(stdout)
          [str, key, customBrowserPath, browserName, version, headless] = matches

          browser = options.browser

          if browser and not customBrowserPath
            expect(_.capitalize(browser)).to.eq(browserName)

          expect(parseFloat(version)).to.be.a.number

          ## if we are in headed mode or in a browser other
          ## than electron
          if options.headed or (browser and browser isnt "electron")
            expect(headless).not.to.exist
          else
            expect(headless).to.include("(headless)")

        str = normalizeStdout(stdout, options)

        args = _.compact([options.originalTitle, str])

        try
          snapshot(args...)
        catch err
          ## if this error is from a duplicated snapshot key then
          ## ignore it else throw
          if not err.duplicateSnapshotKey
            throw err

      return {
        code:   code
        stdout: stdout
        stderr: stderr
      }

    new Promise (resolve, reject) ->
      sp = cp.spawn "node", args, {
        env: _.chain(process.env)
        .omit("CYPRESS_DEBUG")
        .extend({
          ## FYI: color will already be disabled
          ## because we are piping the child process
          COLUMNS: 100
          LINES: 24
        })
        .defaults({
          DEBUG_COLORS: "1"

          ## prevent any Compression progress
          ## messages from showing up
          VIDEO_COMPRESSION_THROTTLE: 120000

          ## don't fail our own tests running from forked PR's
          CYPRESS_INTERNAL_E2E_TESTS: "1"
        })
        .value()
      }

      ## pipe these to our current process
      ## so we can see them in the terminal
      sp.stdout.pipe(process.stdout)
      sp.stderr.pipe(process.stderr)

      sp.stdout.on "data", (buf) ->
        stdout += buf.toString()
      sp.stderr.on "data", (buf) ->
        stderr += buf.toString()
      sp.on("error", reject)
      sp.on("exit", resolve)
    .tap(copy)
    .then(exit)

  sendHtml: (contents) -> (req, res) ->
    res.set('Content-Type', 'text/html')
    res.send("""
      <!DOCTYPE html>
      <html lang="en">
      <body>
        #{contents}
      </body>
      </html>
    """)
}
