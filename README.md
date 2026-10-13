# Nook

Google Chat, Gmail, Drive, and Calendar in a small macOS app.

I built Nook to keep my work Google account separate from my personal Chrome session. I had been using the free version of Clovery, but sometimes ran into errors. I wanted a simple place for Chat, email, and file sharing, so I made one.

It opens Google's own pages and keeps one account signed in across the services. Docs, Sheets, and Slides open in your browser.

The Camera tab plays an RTSP camera inside Nook using [VLC](https://www.videolan.org/vlc/) installed on your Mac. Use a home VPN to watch remotely. Turn on **Keep Open** to keep video and sound playing in a small corner view while using other tabs. Camera credentials stay in macOS Keychain.

Nook is written in Swift and uses the WebKit already on your Mac. The current Apple Silicon app is **under 1 MB**, compared with **around 300 MB** for the Electron 44.6.0 runtime used in the earlier prototype.

## Try it

You'll need macOS 14 or later and Apple Command Line Tools or Xcode.

```sh
bash scripts/build.sh
open build/Nook.app
```

Version 0.0.1 has been tested on Apple Silicon with a Workspace account. Chat notification banners still need testing, and builds aren't notarized.

Nook isn't affiliated with Google. The app and sidebar icons are original. A code license hasn't been selected yet.
