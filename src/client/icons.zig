//! The Maps icons. The transport icons are the outlines Maps-js ships in public/assets/images
//! (Material Symbols); the others are simple shapes drawn here.

const zui = @import("zui");
const Icon = zui.Icon;
const circle = zui.icon.circle;

const material = .{ .fill = true, .box = 960, .origin = .{ 0, -960 } };

pub const car: Icon = .{ .paths = &.{"M240-200v40q0 17-11.5 28.5T200-120h-40q-17 0-28.5-11.5T120-160v-320l84-240q6-18 21.5-29t34.5-11h440q19 0 34.5 11t21.5 29l84 240v320q0 17-11.5 28.5T800-120h-40q-17 0-28.5-11.5T720-160v-40H240Zm-8-360h496l-42-120H274l-42 120Zm-32 80v200-200Zm100 160q25 0 42.5-17.5T360-380q0-25-17.5-42.5T300-440q-25 0-42.5 17.5T240-380q0 25 17.5 42.5T300-320Zm360 0q25 0 42.5-17.5T720-380q0-25-17.5-42.5T660-440q-25 0-42.5 17.5T600-380q0 25 17.5 42.5T660-320Zm-460 40h560v-200H200v200Z"}, .fill = material.fill, .box = material.box, .origin = material.origin };
pub const motorcycle: Icon = .{ .paths = &.{"M428-520h-70 150-80ZM200-200q-83 0-141.5-58.5T0-400q0-83 58.5-141.5T200-600h464l-80-80H440v-80h143q16 0 30.5 6t25.5 17l139 139q78 6 130 63t52 135q0 83-58.5 141.5T760-200q-83 0-141.5-58.5T560-400q0-18 2.5-35.5T572-470L462-360h-66q-14 70-69 115t-127 45Zm560-80q50 0 85-35t35-85q0-50-35-85t-85-35q-50 0-85 35t-35 85q0 50 35 85t85 35Zm-560 0q38 0 68.5-22t43.5-58H200v-80h112q-13-36-43.5-58T200-520q-50 0-85 35t-35 85q0 50 35 85t85 35Zm198-160h30l80-80H358q15 17 25 37t15 43Z"}, .fill = material.fill, .box = material.box, .origin = material.origin };
pub const truck: Icon = .{ .paths = &.{"M155-195q-35-35-35-85H40v-440q0-33 23.5-56.5T120-800h560v160h120l120 160v200h-80q0 50-35 85t-85 35q-50 0-85-35t-35-85H360q0 50-35 85t-85 35q-50 0-85-35Zm113.5-56.5Q280-263 280-280t-11.5-28.5Q257-320 240-320t-28.5 11.5Q200-297 200-280t11.5 28.5Q223-240 240-240t28.5-11.5ZM120-360h32q17-18 39-29t49-11q27 0 49 11t39 29h272v-360H120v360Zm628.5 108.5Q760-263 760-280t-11.5-28.5Q737-320 720-320t-28.5 11.5Q680-297 680-280t11.5 28.5Q703-240 720-240t28.5-11.5ZM680-440h170l-90-120h-80v120ZM360-540Z"}, .fill = material.fill, .box = material.box, .origin = material.origin };
pub const bicycle: Icon = .{ .paths = &.{"M200-80q-83 0-141.5-58.5T0-280q0-83 58.5-141.5T200-480q83 0 141.5 58.5T400-280q0 83-58.5 141.5T200-80Zm85-115q35-35 35-85t-35-85q-35-35-85-35t-85 35q-35 35-35 85t35 85q35 35 85 35t85-35Zm155-5v-200L312-512q-12-11-18-25.5t-6-30.5q0-16 6.5-30.5T312-624l112-112q12-12 27.5-18t32.5-6q17 0 32.5 6t27.5 18l76 76q28 28 64 44t76 16v80q-57 0-108.5-22T560-604l-32-32-96 96 88 92v248h-80Zm123.5-563.5Q540-787 540-820t23.5-56.5Q587-900 620-900t56.5 23.5Q700-853 700-820t-23.5 56.5Q653-740 620-740t-56.5-23.5ZM760-80q-83 0-141.5-58.5T560-280q0-83 58.5-141.5T760-480q83 0 141.5 58.5T960-280q0 83-58.5 141.5T760-80Zm85-115q35-35 35-85t-35-85q-35-35-85-35t-85 35q-35 35-35 85t35 85q35 35 85 35t85-35Z"}, .fill = material.fill, .box = material.box, .origin = material.origin };
pub const walk: Icon = .{ .paths = &.{"m280-40 112-564-72 28v136h-80v-188l202-86q14-6 29.5-7t29.5 4q14 5 26.5 14t20.5 23l40 64q26 42 70.5 69T760-520v80q-70 0-125-29t-94-74l-25 123 84 80v300h-80v-260l-84-64-72 324h-84Zm203.5-723.5Q460-787 460-820t23.5-56.5Q507-900 540-900t56.5 23.5Q620-853 620-820t-23.5 56.5Q573-740 540-740t-56.5-23.5Z"}, .fill = material.fill, .box = material.box, .origin = material.origin };

pub const search: Icon = .{ .paths = &.{ circle(11, 11, 7), "M16.5 16.5L21 21" } };
pub const locate: Icon = .{ .paths = &.{ circle(12, 12, 7), circle(12, 12, 2.5), "M12 2v3M12 19v3M2 12h3M19 12h3" } };
pub const back: Icon = .{ .paths = &.{"M19 12H5M11 18l-6-6 6-6"} };
pub const swap: Icon = .{ .paths = &.{"M8 20V5M4 9l4-4 4 4M16 4v15M12 15l4 4 4-4"} };
pub const close: Icon = .{ .paths = &.{"M6 6l12 12M18 6L6 18"} };
pub const straight: Icon = .{ .paths = &.{"M12 20V5M5 11l7-7 7 7"}, .stroke = 3 };
pub const turn_right: Icon = .{ .paths = &.{"M6 20v-7a4 4 0 0 1 4-4h9M15 5l4 4-4 4"}, .stroke = 3 };
pub const turn_left: Icon = .{ .paths = &.{"M18 20v-7a4 4 0 0 0-4-4H5M9 5L5 9l4 4"}, .stroke = 3 };
pub const arrived: Icon = .{ .paths = &.{ circle(12, 12, 9), "M8 12.5l3 3 5-6" }, .stroke = 3 };
/// The vehicle while navigating, pointing up (turned by the heading).
pub const arrow: Icon = .{ .paths = &.{"M12 2L21 20L12 16.5L3 20Z"}, .fill = true };
/// The destination pin (Maps-js's), tip at the bottom.
pub const pin: Icon = .{ .paths = &.{"M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z"}, .fill = true };
/// The zoom buttons (MapLibre's bold plus and minus).
pub const plus: Icon = .{ .paths = &.{"M12 5v14M5 12h14"}, .stroke = 3 };
pub const minus: Icon = .{ .paths = &.{"M5 12h14"}, .stroke = 3 };
