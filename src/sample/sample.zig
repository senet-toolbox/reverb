const Reverb = @import("reverb");
const Context = Reverb.Context;

pub fn getSample(ctx: *Context) !void {
    try ctx.STRING("Get Sample");
}

pub fn postSample(ctx: *Context) !void {
    try ctx.STRING("Post Sample");
}

pub fn deleteSample(ctx: *Context) !void {
    try ctx.STRING("Delete Sample");
}
