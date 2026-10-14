package com.claude.cameo.bridge.util;

import com.dassault_systemes.modeler.foundation.diagram.ylayout.DiagramLayouter;
import com.dassault_systemes.modeler.foundation.editing.CompositeCommand;
import com.nomagic.magicdraw.core.Application;
import com.nomagic.magicdraw.properties.PropertyManager;
import com.nomagic.magicdraw.uml.symbols.DiagramPresentationElement;
import com.nomagic.magicdraw.uml.symbols.PresentationElement;
import com.nomagic.magicdraw.uml.symbols.PropertyBasedPresentationElement;

import java.lang.reflect.Method;

/**
 * Shims for APIs that changed between Cameo 2024x and 2026x.
 */
public final class Cameo2026Compat {

    private Cameo2026Compat() {
    }

    /** 2026x moved getPropertyManager() from PresentationElement to PropertyBasedPresentationElement. */
    public static PropertyManager propertyManager(PresentationElement pe) {
        if (pe instanceof PropertyBasedPresentationElement pb) {
            return pb.getPropertyManager();
        }
        throw new IllegalStateException("Presentation element type " + pe.getClass().getSimpleName()
                + " does not expose a PropertyManager in this Cameo version");
    }

    /** 2026x replaced DiagramPresentationElement.layout(boolean) with DiagramLayouter. */
    @SuppressWarnings({"rawtypes", "unchecked"})
    public static boolean layout(DiagramPresentationElement dpe) {
        DiagramLayouter layouter = dpe.getDefaultDiagramLayouter();
        if (layouter == null || !layouter.canLayout(dpe)) {
            return false;
        }
        return layouter.layout(dpe, (CompositeCommand) null);
    }

    /** 2026x removed isDiagramWindowActive(); compare against the project's active diagram instead. */
    public static boolean isDiagramWindowActive(DiagramPresentationElement dpe) {
        try {
            Object project = Application.getInstance().getProject();
            if (project == null) {
                return false;
            }
            Method m = project.getClass().getMethod("getActiveDiagram");
            return m.invoke(project) == dpe;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * 2026x removed isDiagramWindowOpen(). Approximated as "is the active diagram";
     * callers that see false just call dpe.open(), which is harmless on an open diagram.
     */
    public static boolean isDiagramWindowOpen(DiagramPresentationElement dpe) {
        return isDiagramWindowActive(dpe);
    }
}