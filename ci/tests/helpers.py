from PIL import Image


def write_png(path, size, color):
    """Write a solid-colour PNG of the given (width, height)."""
    Image.new("RGB", size, color).save(path, "PNG")
