// jsdom does not implement scrolling; the router calls it on navigation.
window.scrollTo = () => {}
