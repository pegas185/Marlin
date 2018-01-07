/** Edit History:
      (V2)WorkerDrone: Initial changes for MPCNC
      (V3_SDcard)SLC:
        - Removed odd characters
        - M25 (or M1) keeps steppers active during tool change,
          Problem is that the steppers are disabled after a 60s timeout,
          So "M84 S1800" was added to change the timeout to 30 minutes.
        - On tool change retract Z15, X-30, Y-30,
          Display "Change to Tool T#" to LCD and Pause SD
        - To resume after tool change select "resume Printing" from menu
      (V4_SDcard)SLC:
        - Added Z move to +5 at the beginning to prevent dragging over the surface
          to the first operation.
      (V5_SDcard)SLC:
        - Changed the above initial Z move to +10 to avoid hitting and cutting
          my hold down clamps:).
      (V6_SDcard)Bryan:
        - Changed [writeBlock(gMotionModal.format(1), "X0", "Y0", "Z15"); // Return to zero.] Was previously "Z0" and hitting origin
      (V7_ModelmaniakCNC) Roman:
        - Forked as a driver for Modelmaniak Marlin-based CNC
        - Support laser cutter
        - Support milling
        - uses M3, M4, M5 commands to start spindle, laser
        - should be placed to ~/Autodesk/Fusion 360 CAM/Posts
        - you should define external editor in Fusion 360 CAM preferences to be able check logs in case of error.
**/
/**
  Copyright (C) 2012-2013 by Autodesk, Inc.
  All rights reserved.

  RepRap post processor configuration.

  $Revision: -1 $
  $Date: $

  FORKID {996580A5-D617-4b85-9DA2-C4EF3CBF92FC}
*/

description = "Modelmaniak v07";
vendor = "Modelmaniak.pl";
vendorUrl = "modelmaniak.pl";
legal = "Copyright (C) 2012-2013 by Autodesk, Inc.";
certificationLevel = 2;
minimumRevision = 24000;

extension = "gcode";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING | CAPABILITY_JET;
tolerance = spatial(0.02, MM);
highFeedrate = (unit == IN) ? 500 : 2000;
debugMode = true;


debug("Output from CPS");

// user-defined properties
properties = {
  writeMachine: true, // write machine
  writeTools: true, // writes the tools
  preloadTool: true, // preloads next tool on tool change if any
  showSequenceNumbers: true, // show sequence numbers
  sequenceNumberStart: 10, // first sequence number
  sequenceNumberIncrement: 5, // increment for sequence numbers
  optionalStop: true, // optional stop
  separateWordsWithSpace: true, // specifies that the words should be separated with a white space
  useG0: false // allow G0 when moving along more than one axis
};

var numberOfToolSlots = 9999;

var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var feedFormat = createFormat({decimals:(unit == MM ? 1 : 2)});
var toolFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var milliFormat = createFormat({decimals:0}); // milliseconds
var taperFormat = createFormat({decimals:1, scale:DEG});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);
var feedOutput = createVariable({prefix:"F",force:true}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

var gMotionModal = createModal({force:true}, gFormat); // modal group 1 // G0-G1, ...
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21

var WARNING_WORK_OFFSET = 0;

// collected state
var sequenceNumber;
var currentWorkOffset;

/**
  Writes the specified block.
*/
function writeBlock() {
  if (properties.showSequenceNumbers) {
    writeWords2("N" + sequenceNumber, arguments);
    sequenceNumber += properties.sequenceNumberIncrement;
  } else {
    writeWords(arguments);
  }
}

function formatComment(text) {
  return ";" + String(text).replace(/[\(\)]/g, "");
}

/**
  Output a comment.
*/
function writeComment(text) {
  writeln(formatComment(text));
}

function onOpen() {
  if (!properties.separateWordsWithSpace) {
    setWordSeparator("");
  }

  sequenceNumber = properties.sequenceNumberStart;
  //writeln("%");

  if (programName) {
    writeComment(programName);
  }
  if (programComment) {
    writeComment(programComment);
  }

  // dump machine configuration
  var vendor = machineConfiguration.getVendor();
  var model = machineConfiguration.getModel();
  var description = machineConfiguration.getDescription();

  if (properties.writeMachine && (vendor || model || description)) {
    writeComment(localize("Machine"));
    if (vendor) {
      writeComment("  " + localize("vendor") + ": " + vendor);
    }
    if (model) {
      writeComment("  " + localize("model") + ": " + model);
    }
    if (description) {
      writeComment("  " + localize("description") + ": "  + description);
    }
  }

  // dump tool information
  if (properties.writeTools) {
    var zRanges = {};
    if (is3D()) {
      var numberOfSections = getNumberOfSections();
      for (var i = 0; i < numberOfSections; ++i) {
        var section = getSection(i);
        var zRange = section.getGlobalZRange();
        var tool = section.getTool();
        if (zRanges[tool.number]) {
          zRanges[tool.number].expandToRange(zRange);
        } else {
          zRanges[tool.number] = zRange;
        }
      }
    }

    var tools = getToolTable();
    if (tools.getNumberOfTools() > 0) {
      for (var i = 0; i < tools.getNumberOfTools(); ++i) {
        var tool = tools.getTool(i);
        var comment = "T" + toolFormat.format(tool.number) + "  " +
          "D=" + xyzFormat.format(tool.diameter) + " " +
          localize("CR") + "=" + xyzFormat.format(tool.cornerRadius);
        if ((tool.taperAngle > 0) && (tool.taperAngle < Math.PI)) {
          comment += " " + localize("TAPER") + "=" + taperFormat.format(tool.taperAngle) + localize("deg");
        }
        if (zRanges[tool.number]) {
          comment += " - " + localize("ZMIN") + "=" + xyzFormat.format(zRanges[tool.number].getMinimum());
        }
        comment += " - " + getToolTypeName(tool.type);
        writeComment(comment);
      }
    }
  }

  // absolute coordinates
  writeBlock(gAbsIncModal.format(90));

  switch (unit) {
  case IN:
    writeBlock(";Units in inches.");
    break;
  case MM:
    writeBlock(";Units in mm");
    break;
  }

  writeBlock(gFormat.format(92) + SP + "X0" + SP + "Y0" + SP + "Z0"); //included to set the machine to zero
//SLC Edit: Keep the steppers enabled for 30 minutes to allow time for tardy tool changes.
  writeBlock("M84 S1800 ;Change Stepper disable timeout to 30 minutes");
//SLC Edit:
  writeBlock("G1 Z10 F2000 ; Lift Z 10mm to avoid dragging to first operation");
}

function onComment(message) {
  writeComment(message);
}

/** Force output of X, Y, and Z. */
function forceXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

/** Force output of X, Y, Z, A, B, C, and F on next output. */
function forceAny() {
  forceXYZ();
  feedOutput.reset();
}

function onSection() {
  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.number != getPreviousSection().getTool().number);

  var retracted = false; // specifies that the tool has been retracted to the safe plane
  var newWorkOffset = isFirstSection() ||
    (getPreviousSection().workOffset != currentSection.workOffset); // work offset changes
  var newWorkPlane = isFirstSection() ||
    !isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), currentSection.getGlobalInitialToolAxis());
  if (insertToolCall || newWorkOffset || newWorkPlane) {

    // stop spindle before retract during tool change
    if (insertToolCall && !isFirstSection()) {
      onCommand(COMMAND_STOP_SPINDLE);
    }

    // retract to safe plane
    retracted = true;
 //writeBlock(gMotionModal.format(1), "Z0"); //added to return tool to start upon change
 //writeBlock(gMotionModal.format(1), "X0", "Y0"); //return to starting point
  // writeBlock(gFormat.format(28)); //removed to stop homing.
    zOutput.reset();
  }

  writeln("");

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment(comment);
    }
  }

  if (insertToolCall) {
    retracted = true;
    setCoolant(COOLANT_OFF);

    if (!isFirstSection() && properties.optionalStop) {
    //SLC Edit: tool change retract position
    // For
    writeBlock("G1 Z15 F2000 ;T" + toolFormat.format(tool.number));
    writeBlock("G1 X-20 Y-20 F2000 ;T" + toolFormat.format(tool.number));
    writeBlock("M117 Change to Tool T" + toolFormat.format(tool.number));
    writeBlock("M25 ;Pause for Tool T" + toolFormat.format(tool.number));
//      onCommand(COMMAND_OPTIONAL_STOP);

    }

    if (tool.number > numberOfToolSlots) {
      warning(localize("Tool number exceeds maximum value."));
    }

    if (tool.comment) {
      writeComment(tool.comment);
    }
    var showToolZMin = false;
    if (showToolZMin) {
      if (is3D()) {
        var numberOfSections = getNumberOfSections();
        var zRange = currentSection.getGlobalZRange();
        var number = tool.number;
        for (var i = currentSection.getId() + 1; i < numberOfSections; ++i) {
          var section = getSection(i);
          if (section.getTool().number != number) {
            break;
          }
          zRange.expandToRange(section.getGlobalZRange());
        }
        writeComment(localize("ZMIN") + "=" + zRange.getMinimum());
      }
    }

    if (properties.preloadTool) {
      var nextTool = getNextTool(tool.number);
      if (nextTool) {
        writeBlock(";T" + toolFormat.format(nextTool.number));
      } else {
        // preload first tool
        var section = getSection(0);
        var firstToolNumber = section.getTool().number;
        if (tool.number != firstToolNumber) {
          writeBlock(";T" + toolFormat.format(firstToolNumber));
        }
      }
    }
  }

  if (insertToolCall ||
      isFirstSection() ||
      (rpmFormat.areDifferent(tool.spindleRPM, sOutput.getCurrent())) ||
      (tool.clockwise != getPreviousSection().getTool().clockwise)) {
    if (!tool.isJetTool() && tool.spindleRPM < 1) {
      error(localize("Spindle speed out of range."));
    }
    if (tool.spindleRPM > 99999) {
      warning(localize("Spindle speed exceeds maximum value."));
    }


    debug("Tool type: " + tool.getType());
    debug("Tool isTurningTool: " + tool.isTurningTool());
    debug("Tool isJetTool: " + tool.isJetTool());
    debug("Tool isLiveTool: " + tool.isLiveTool());
    debug("Tool isDrill: " + tool.isDrill());
    debug("TOOL_UNSPECIFIED = " + TOOL_UNSPECIFIED);
    debug("TOOL_DRILL = " + TOOL_DRILL);
    debug("TOOL_DRILL_CENTER = " + TOOL_DRILL_CENTER);
    debug("TOOL_DRILL_SPOT = " + TOOL_DRILL_SPOT);
    debug("TOOL_DRILL_BLOCK = " + TOOL_DRILL_BLOCK);
    debug("TOOL_MILLING_END_FLAT = " + TOOL_MILLING_END_FLAT);
    debug("TOOL_MILLING_END_BALL = " + TOOL_MILLING_END_BALL);
    debug("TOOL_MILLING_END_BULLNOSE = " + TOOL_MILLING_END_BULLNOSE);
    debug("TOOL_MILLING_CHAMFER = " + TOOL_MILLING_CHAMFER);
    debug("TOOL_MILLING_FACE = " + TOOL_MILLING_FACE);
    debug("TOOL_MILLING_SLOT = " + TOOL_MILLING_SLOT);
    debug("TOOL_MILLING_RADIUS = " + TOOL_MILLING_RADIUS);
    debug("TOOL_MILLING_DOVETAIL = " + TOOL_MILLING_DOVETAIL);
    debug("TOOL_MILLING_TAPERED = " + TOOL_MILLING_TAPERED);
    debug("TOOL_MILLING_LOLLIPOP = " + TOOL_MILLING_LOLLIPOP);
    debug("TOOL_TAP_RIGHT_HAND = " + TOOL_TAP_RIGHT_HAND);
    debug("TOOL_TAP_LEFT_HAND = " + TOOL_TAP_LEFT_HAND);
    debug("TOOL_REAMER = " + TOOL_REAMER);
    debug("TOOL_BORING_BAR = " + TOOL_BORING_BAR);
    debug("TOOL_COUNTER_BORE = " + TOOL_COUNTER_BORE);
    debug("TOOL_COUNTER_SINK = " + TOOL_COUNTER_SINK);
    debug("TOOL_HOLDER_ONLY = " + TOOL_HOLDER_ONLY);
    debug("TOOL_TURNING_GENERAL = " + TOOL_TURNING_GENERAL);
    debug("TOOL_TURNING_THREADING = " + TOOL_TURNING_THREADING);
    debug("TOOL_TURNING_GROOVING = " + TOOL_TURNING_GROOVING);
    debug("TOOL_TURNING_BORING = " + TOOL_TURNING_BORING);
    debug("TOOL_TURNING_CUSTOM = " + TOOL_TURNING_CUSTOM);
    debug("TOOL_PROBE = " + TOOL_PROBE);
    debug("TOOL_WIRE = " + TOOL_WIRE);
    debug("TOOL_WATER_JET = " + TOOL_WATER_JET);
    debug("TOOL_LASER_CUTTER = " + TOOL_LASER_CUTTER);
    debug("TOOL_WELDER = " + TOOL_WELDER);
    debug("TOOL_GRINDER = " + TOOL_GRINDER);
    debug("TOOL_MILLING_FORM = " + TOOL_MILLING_FORM);
    debug("TOOL_PLASMA_CUTTER = " + TOOL_PLASMA_CUTTER);
    debug("TOOL_MARKER = " + TOOL_MARKER);
    debug("TOOL_MILLING_THREAD = " + TOOL_MILLING_THREAD);



    if(!tool.isJetTool()){
      writeBlock(
        mFormat.format(tool.clockwise ? 3 : 4), sOutput.format(tool.spindleRPM)
        //DuctSoup Edit: Use RAMPS Fan On to turn spindle back on.
        //mFormat.format(106)
      );
    }
  }

  // wcs
  var workOffset = currentSection.workOffset;
  if (workOffset != 0) {
    warningOnce(localize("Work offset is not supported."), WARNING_WORK_OFFSET);
  }

  forceXYZ();

  { // pure 3D
    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);
  }

  // set coolant after we have positioned at Z
  setCoolant(tool.coolant);

  forceAny();

  var initialPosition = getFramePosition(currentSection.getInitialPosition());
  if (!retracted) {
    if (getCurrentPosition().z < initialPosition.z) {
      writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
    }
  }

  if (insertToolCall || retracted) {
    gMotionModal.reset();
    writeBlock(
      gAbsIncModal.format(90),
      gMotionModal.format(properties.useG0 ? 0 : 1), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y),
      conditional(!properties.useG0, feedOutput.format(highFeedrate))
    );
    writeBlock(gMotionModal.format(properties.useG0 ? 0 : 1), zOutput.format(initialPosition.z), conditional(!properties.useG0, feedOutput.format(highFeedrate)));
  } else {
    writeBlock(
      gAbsIncModal.format(90),
      gMotionModal.format(properties.useG0 ? 0 : 1),
      xOutput.format(initialPosition.x),
      yOutput.format(initialPosition.y),
      conditional(!properties.useG0, feedOutput.format(highFeedrate))
    );
  }
}

var currentCoolantMode = undefined;

function setCoolant(coolant) {
  if (coolant == currentCoolantMode) {
    return; // coolant is already active
  }

  var m = undefined;
  if (coolant == COOLANT_OFF) {
    m = 9;
    //writeBlock(";coolant off");
    currentCoolantMode = COOLANT_OFF;
    return;
  }

  if (currentCoolantMode != COOLANT_OFF) {
    setCoolant(COOLANT_OFF);
  }

  switch (coolant) {
  case COOLANT_FLOOD:
    m = 8;
    break;
  default:
    warning(localize("Coolant not supported."));
    if (currentCoolantMode == COOLANT_OFF) {
      return;
    }
    coolant = COOLANT_OFF;
    m = 9;
  }

  //writeBlock(";coolant is ");
  currentCoolantMode = coolant;
}

function onDwell(seconds) {
  if (seconds > 99999.999) {
    warning(localize("Dwelling time is out of range."));
  }
  milliseconds = clamp(1, seconds * 1000, 99999);
  writeBlock(gFormat.format(4), "P" + milliFormat.format(milliseconds));
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(sOutput.format(spindleSpeed));
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
  pendingRadiusCompensation = radiusCompensation;
}

function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      error(localize("Radius compensation mode cannot be changed at rapid traversal."));
      return;
    }
    if (!properties.useG0) {
      writeBlock(gMotionModal.format(1), x, y, z, feedOutput.format(highFeedrate));
    } else {
      writeBlock(gMotionModal.format(0), x, y, z);
    }
    feedOutput.reset();
  }
}

function onLinear(_x, _y, _z, feed) {
  // at least one axis is required
  if (pendingRadiusCompensation >= 0) {
    // ensure that we end at desired position when compensation is turned off
    xOutput.reset();
    yOutput.reset();
  }
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feed);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      error(localize("Radius compensation mode is not supported."));
      return;
    } else {
      writeBlock(gMotionModal.format(1), x, y, z, f);
    }
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      feedOutput.reset(); // force feed on next line
    } else {
      writeBlock(gMotionModal.format(1), f);
    }
  }
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  linearize(tolerance);
}
// Fan On M106, Fan Off M107
var mapCommand = {
  COMMAND_STOP:0,
  COMMAND_OPTIONAL_STOP:1,
  COMMAND_SPINDLE_CLOCKWISE:3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE:4,
  COMMAND_STOP_SPINDLE:5,
  COMMAND_POWER_OFF:5,
};

function onCommand(command) {

  debug("Command: " + command);
  //onUnsupportedCommand(command);

  switch (command) {
  case COMMAND_START_SPINDLE:
    onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
    return;
  case COMMAND_LOCK_MULTI_AXIS:
    return;
  case COMMAND_UNLOCK_MULTI_AXIS:
    return;
  case COMMAND_BREAK_CONTROL:
    return;
  case COMMAND_TOOL_MEASURE:
    return;
  case COMMAND_POWER_ON:
    if(tool.isJetTool()){
      writeBlock(mFormat.format(3), sOutput.format(255));
    } else {
      writeBlock(mFormat.format(tool.clockwise ? 3 : 4), sOutput.format(tool.spindleRPM));
    }
    return;
  }

  var stringId = getCommandStringId(command);
  var mcode = mapCommand[stringId];
  if (mcode != undefined) {
    writeBlock(mFormat.format(mcode));
  } else {
    writeComment("unsupported command: " + command);
    onUnsupportedCommand(command);
  }
}

function onSectionEnd() {
   forceAny();
}

function onClose() {
  setCoolant(COOLANT_OFF);

  writeBlock(gMotionModal.format(1), "Z15"); // Avoid dragging across stock.
  writeBlock(gMotionModal.format(1), "X0", "Y0", "Z15"); // Return to zero.
  zOutput.reset();


  onCommand(COMMAND_STOP_SPINDLE);
  writeBlock(mFormat.format(84) + "; Turn steppers off");
  //writeln("%");
}
