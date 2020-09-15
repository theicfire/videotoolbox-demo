This plans to be a low-resource h.264 video player, which we'll be using to build remote desktop software.

# Requirements
- You need SDL2. `brew install sdl2` should work. You may have to do something about linking headers -- look at the output of this command.

# How to run via node
- Use node v12.10.0. v12.14.0 does not work :( :(. It gives an SDL error, lameeee
- You also need to install [yarn](https://yarnpkg.com/lang/en/docs/install/#mac-stable)
- `tar xzf frames.tar.gz`
- Run `node index.js`

# How to run via XCode
- `tar xzf frames.tar.gz`
- Open xcode-alternative in XCode
- Modify the path in main.m for player.play
- Run!
